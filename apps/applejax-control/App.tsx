import { StatusBar } from 'expo-status-bar';
import * as DocumentPicker from 'expo-document-picker';
import { useCallback, useEffect, useRef, useState } from 'react';
import {
  Alert,
  KeyboardAvoidingView,
  Modal,
  Platform,
  Pressable,
  StyleSheet,
  Text,
  TextInput,
  View
} from 'react-native';
import { Buffer } from 'buffer';
import TcpSocket from 'react-native-tcp-socket';
import { CameraView, useCameraPermissions, type BarcodeScanningResult } from 'expo-camera';

import AppleJaxAudio from './modules/applejax-audio';

type Mode = 'idle' | 'mic' | 'file';
type ConnState = 'disconnected' | 'connecting' | 'connected' | 'error';

const MAGIC = Buffer.from([0x41, 0x50, 0x4a, 0x58]); // "APJX"
const HEADER_SIZE = 8;

export default function App() {
  const [mode, setMode] = useState<Mode>('idle');
  const [host, setHost] = useState('192.168.1.100');
  const [port, setPort] = useState('9999');
  const [conn, setConn] = useState<ConnState>('disconnected');
  const [status, setStatus] = useState('Idle');
  const [filename, setFilename] = useState<string | null>(null);
  // Prevents a second tap while startMic/playFile is in-flight (before state event arrives)
  const [starting, setStarting] = useState(false);

  const socketRef = useRef<ReturnType<typeof TcpSocket.createConnection> | null>(null);
  const rmsRef = useRef(0);
  const sentChunksRef = useRef(0);
  const droppedRef = useRef(0);
  // Bounded ring of un-sent frames. Caps memory + audio latency at ~370ms
  // (8 frames × ~46ms each). On overflow we drop the OLDEST frame so the
  // visualizer stays close to live; the dropped counter is exposed in the UI.
  const queueRef = useRef<Buffer[]>([]);
  const queuedFramesRef = useRef(0);
  const QUEUE_CAP = 8;

  // Try to push as many frames as TcpSocket will accept without backpressure.
  // Returns when the socket either reports backpressure (write returns false)
  // or the queue is empty. Safe to call from both 'pcm' and 'drain' handlers.
  const flushQueue = useCallback(() => {
    const sock = socketRef.current;
    if (!sock) return;
    while (queueRef.current.length > 0) {
      const frame = queueRef.current.shift()!;
      const ok = sock.write(frame as any);
      sentChunksRef.current += 1;
      if (ok === false) {
        // Backpressure: stop flushing. 'drain' will fire later and call us again.
        break;
      }
    }
    queuedFramesRef.current = queueRef.current.length;
  }, []);

  // Subscribe to PCM events
  useEffect(() => {
    const pcmSub = AppleJaxAudio.addListener('pcm', ({ data, rms: r }) => {
      rmsRef.current = r;
      const sock = socketRef.current;
      if (!sock) {
        droppedRef.current += 1;
        return;
      }
      try {
        const payload = Buffer.from(data, 'base64');
        const frame = Buffer.alloc(HEADER_SIZE + payload.length);
        MAGIC.copy(frame, 0);
        frame.writeUInt32LE(payload.length, 4);
        payload.copy(frame, HEADER_SIZE);
        // Cap the queue: if full, drop the oldest frame so we stay near live.
        if (queueRef.current.length >= QUEUE_CAP) {
          queueRef.current.shift();
          droppedRef.current += 1;
        }
        queueRef.current.push(frame);
        queuedFramesRef.current = queueRef.current.length;
        flushQueue();
      } catch (e) {
        console.warn('[appleJax] pcm write error:', e);
        droppedRef.current += 1;
      }
    });
    const stateSub = AppleJaxAudio.addListener('state', ({ state, error }) => {
      console.log('[appleJax] state event:', state, error ?? '');
      setMode(state);
      if (error) setStatus(`Error: ${error}`);
      else setStatus(state === 'idle' ? 'Idle' : `Streaming (${state})`);
    });
    return () => {
      pcmSub.remove();
      stateSub.remove();
    };
  }, []);

  const connectTo = useCallback((targetHost: string, targetPort: string) => {
    const portNum = parseInt(targetPort, 10);
    if (!targetHost || !portNum) {
      Alert.alert('Bad address', 'Enter host and port.');
      return;
    }
    // Tear down any existing socket cleanly before opening a new one — avoids the
    // "two sockets, both holding the queue" race when scanning a fresh QR.
    if (socketRef.current) {
      try { socketRef.current.destroy(); } catch {}
      socketRef.current = null;
    }
    setConn('connecting');
    setStatus(`Connecting to ${targetHost}:${portNum}…`);
    const sock = TcpSocket.createConnection(
      { host: targetHost, port: portNum, tls: false },
      () => {
        console.log(`[appleJax] connected to ${targetHost}:${portNum}`);
        try { sock.setNoDelay?.(true); } catch {}
        setConn('connected');
        setStatus(`Connected to ${targetHost}:${portNum}`);
      }
    );
    sock.on('error', (err: Error) => {
      console.error('[appleJax] socket error:', err.message);
      setConn('error');
      setStatus(`Socket error: ${err.message}`);
      queueRef.current = [];
      queuedFramesRef.current = 0;
      socketRef.current = null;
    });
    sock.on('close', () => {
      console.log('[appleJax] socket closed');
      setConn('disconnected');
      setStatus('Disconnected');
      queueRef.current = [];
      queuedFramesRef.current = 0;
      socketRef.current = null;
    });
    sock.on('drain', () => {
      flushQueue();
    });
    socketRef.current = sock;
  }, [flushQueue]);

  const connect = useCallback(() => {
    connectTo(host, port);
  }, [connectTo, host, port]);

  const disconnect = useCallback(() => {
    socketRef.current?.destroy();
    socketRef.current = null;
    setConn('disconnected');
    setStatus('Disconnected');
  }, []);

  // QR scanning state. Camera permission is requested lazily — only when the user
  // taps "Scan QR" — so the app doesn't ask on first launch.
  const [scanning, setScanning] = useState(false);
  const [permission, requestPermission] = useCameraPermissions();
  const handledScan = useRef(false);

  // Accepts: applejax://host:port  |  http(s)://host:port  |  host:port
  const parsePairingCode = useCallback((raw: string): { host: string; port: string } | null => {
    let body = raw.trim();
    body = body.replace(/^applejax:\/\//i, '').replace(/^https?:\/\//i, '');
    body = body.split('/')[0]; // drop trailing path
    const idx = body.lastIndexOf(':');
    if (idx <= 0) return null;
    const h = body.substring(0, idx);
    const p = body.substring(idx + 1);
    if (!h || !/^\d+$/.test(p)) return null;
    return { host: h, port: p };
  }, []);

  const openScanner = useCallback(async () => {
    if (!permission?.granted) {
      const r = await requestPermission();
      if (!r.granted) {
        Alert.alert('Camera access needed', 'Enable camera access in Settings to scan QR codes.');
        return;
      }
    }
    handledScan.current = false;
    setScanning(true);
  }, [permission, requestPermission]);

  const onBarcode = useCallback((result: BarcodeScanningResult) => {
    if (handledScan.current) return; // CameraView fires multiple times per QR
    handledScan.current = true;
    const parsed = parsePairingCode(result.data);
    setScanning(false);
    if (!parsed) {
      Alert.alert('Bad QR', `Couldn't parse "${result.data}". Expected host:port.`);
      return;
    }
    setHost(parsed.host);
    setPort(parsed.port);
    // Connect immediately with the parsed values — don't wait for setHost/setPort
    // to flush through React state, otherwise `connect()` would still see stale args.
    connectTo(parsed.host, parsed.port);
  }, [parsePairingCode, connectTo]);

  const startMic = useCallback(async () => {
    try {
      setStarting(true);
      console.log('[appleJax] startMic called');
      await AppleJaxAudio.startMic();
      console.log('[appleJax] startMic resolved');
    } catch (e) {
      console.error('[appleJax] startMic error:', e);
      Alert.alert('Mic error', String(e));
    } finally {
      setStarting(false);
    }
  }, []);

  const stopMic = useCallback(async () => {
    try { await AppleJaxAudio.stopMic(); } catch {}
  }, []);

  const pickAndPlay = useCallback(async () => {
    try {
      const res = await DocumentPicker.getDocumentAsync({
        type: 'audio/*',
        copyToCacheDirectory: true,
        multiple: false
      });
      if (res.canceled || !res.assets?.length) return;
      const asset = res.assets[0];
      console.log('[appleJax] playFile:', asset.name, asset.uri);
      setFilename(asset.name ?? 'file');
      setStarting(true);
      await AppleJaxAudio.playFile(asset.uri);
      console.log('[appleJax] playFile resolved');
    } catch (e) {
      console.error('[appleJax] playFile error:', e);
      Alert.alert('File error', String(e));
    } finally {
      setStarting(false);
    }
  }, []);

  const stopFile = useCallback(async () => {
    try { await AppleJaxAudio.stopFile(); } catch {}
  }, []);

  const isStreaming = mode !== 'idle';
  const canStart = conn === 'connected' && !isStreaming && !starting;

  return (
    <KeyboardAvoidingView
      style={styles.container}
      behavior={Platform.OS === 'ios' ? 'padding' : undefined}
    >
      <StatusBar style="light" />

      <View style={styles.header}>
        <Text style={styles.title}>appleJax Control</Text>
        <Text style={styles.subtitle}>{status}</Text>
      </View>

      <View style={styles.section}>
        <Text style={styles.label}>Pair with Apple TV</Text>
        <Pressable
          style={[styles.button, conn === 'connected' ? styles.buttonDanger : styles.buttonPrimary]}
          onPress={conn === 'connected' ? disconnect : openScanner}
        >
          <Text style={styles.buttonText}>
            {conn === 'connected' ? 'Disconnect' : conn === 'connecting' ? 'Connecting…' : 'Scan QR Code'}
          </Text>
        </Pressable>
        <Text style={styles.label}>or enter manually</Text>
        <View style={styles.row}>
          <TextInput
            style={[styles.input, { flex: 3 }]}
            value={host}
            onChangeText={setHost}
            autoCapitalize="none"
            autoCorrect={false}
            keyboardType="numbers-and-punctuation"
            placeholder="192.168.1.100"
            placeholderTextColor="#555"
            editable={conn !== 'connected'}
          />
          <TextInput
            style={[styles.input, { flex: 1 }]}
            value={port}
            onChangeText={setPort}
            keyboardType="number-pad"
            placeholder="9999"
            placeholderTextColor="#555"
            editable={conn !== 'connected'}
          />
          <Pressable
            style={[styles.button, styles.buttonSecondary, conn === 'connected' ? styles.buttonDisabled : null]}
            disabled={conn === 'connected'}
            onPress={connect}
          >
            <Text style={styles.buttonText}>Go</Text>
          </Pressable>
        </View>
      </View>

      <Modal
        visible={scanning}
        animationType="slide"
        onRequestClose={() => setScanning(false)}
      >
        <View style={styles.scannerContainer}>
          {permission?.granted ? (
            <CameraView
              style={StyleSheet.absoluteFill}
              facing="back"
              barcodeScannerSettings={{ barcodeTypes: ['qr'] }}
              onBarcodeScanned={onBarcode}
            />
          ) : (
            <View style={styles.scannerPermission}>
              <Text style={styles.buttonText}>Camera access needed to scan.</Text>
            </View>
          )}
          <View style={styles.scannerOverlay} pointerEvents="box-none">
            <View style={styles.scannerReticle} />
            <Text style={styles.scannerHint}>Point camera at the QR code on your Apple TV</Text>
            <Pressable
              style={[styles.button, styles.buttonDanger, styles.scannerCancel]}
              onPress={() => setScanning(false)}
            >
              <Text style={styles.buttonText}>Cancel</Text>
            </Pressable>
          </View>
        </View>
      </Modal>

      <View style={styles.section}>
        <Text style={styles.label}>Source</Text>
        <View style={styles.row}>
          <Pressable
            disabled={!canStart && mode !== 'mic'}
            style={[
              styles.button,
              styles.flexButton,
              mode === 'mic' ? styles.buttonActive : styles.buttonSecondary,
              !canStart && mode !== 'mic' ? styles.buttonDisabled : null
            ]}
            onPress={mode === 'mic' ? stopMic : startMic}
          >
            <Text style={styles.buttonText}>{mode === 'mic' ? 'Stop Mic' : 'Mic'}</Text>
          </Pressable>
          <Pressable
            disabled={!canStart && mode !== 'file'}
            style={[
              styles.button,
              styles.flexButton,
              mode === 'file' ? styles.buttonActive : styles.buttonSecondary,
              !canStart && mode !== 'file' ? styles.buttonDisabled : null
            ]}
            onPress={mode === 'file' ? stopFile : pickAndPlay}
          >
            <Text style={styles.buttonText}>{mode === 'file' ? 'Stop File' : 'Pick File'}</Text>
          </Pressable>
        </View>
        {filename && mode === 'file' ? (
          <Text style={styles.meta} numberOfLines={1}>{filename}</Text>
        ) : null}
      </View>

      <View style={styles.section}>
        <Text style={styles.label}>Level</Text>
        <LevelMeter
          rmsRef={rmsRef}
          droppedRef={droppedRef}
          queuedFramesRef={queuedFramesRef}
        />
      </View>
    </KeyboardAvoidingView>
  );
}

// Polls rmsRef at 20 Hz and only re-renders this small subtree, so the
// 21 Hz PCM event stream never re-renders the parent (which contains
// TextInput controls that drop keystrokes if re-rendered constantly).
function LevelMeter({
  rmsRef,
  droppedRef,
  queuedFramesRef,
}: {
  rmsRef: React.MutableRefObject<number>;
  droppedRef: React.MutableRefObject<number>;
  queuedFramesRef: React.MutableRefObject<number>;
}) {
  const [display, setDisplay] = useState({ width: 0, dropped: 0, queued: 0 });
  useEffect(() => {
    const id = setInterval(() => {
      setDisplay({
        width: Math.min(100, Math.round(rmsRef.current * 400)),
        dropped: droppedRef.current,
        queued: queuedFramesRef.current,
      });
    }, 50);
    return () => clearInterval(id);
  }, [rmsRef, droppedRef, queuedFramesRef]);
  return (
    <>
      <View style={styles.meter}>
        <View style={[styles.meterFill, { width: `${display.width}%` }]} />
      </View>
      <Text style={styles.meta}>
        22050 Hz · mono · 1024-frame chunks
        {display.queued > 0 ? ` · queued ${display.queued}` : ''}
        {display.dropped > 0 ? ` · ${display.dropped} dropped` : ''}
      </Text>
    </>
  );
}

const styles = StyleSheet.create({
  container: {
    flex: 1,
    backgroundColor: '#000',
    paddingHorizontal: 24,
    paddingTop: 80,
    gap: 28
  },
  header: { gap: 4 },
  title: { color: '#fff', fontSize: 28, fontWeight: '700' },
  subtitle: { color: '#9aa', fontSize: 14 },
  section: { gap: 8 },
  label: { color: '#9aa', fontSize: 12, textTransform: 'uppercase', letterSpacing: 1 },
  row: { flexDirection: 'row', gap: 8 },
  input: {
    backgroundColor: '#1a1a1d',
    borderRadius: 8,
    color: '#fff',
    fontSize: 16,
    paddingHorizontal: 12,
    paddingVertical: 12
  },
  button: {
    paddingVertical: 14,
    paddingHorizontal: 18,
    borderRadius: 10,
    alignItems: 'center'
  },
  flexButton: { flex: 1 },
  buttonPrimary: { backgroundColor: '#2563eb' },
  buttonSecondary: { backgroundColor: '#1a1a1d' },
  buttonActive: { backgroundColor: '#16a34a' },
  buttonDanger: { backgroundColor: '#dc2626' },
  buttonDisabled: { opacity: 0.4 },
  buttonText: { color: '#fff', fontSize: 16, fontWeight: '600' },
  meter: { height: 14, backgroundColor: '#1a1a1d', borderRadius: 7, overflow: 'hidden' },
  meterFill: { height: '100%', backgroundColor: '#16a34a' },
  meta: { color: '#9aa', fontSize: 12 },
  scannerContainer: { flex: 1, backgroundColor: '#000' },
  scannerPermission: { ...StyleSheet.absoluteFillObject, alignItems: 'center', justifyContent: 'center' },
  scannerOverlay: {
    ...StyleSheet.absoluteFillObject,
    alignItems: 'center',
    justifyContent: 'center',
    paddingHorizontal: 24,
    paddingBottom: 80,
    paddingTop: 80,
  },
  scannerReticle: {
    width: 240,
    height: 240,
    borderColor: '#ffffff',
    borderWidth: 3,
    borderRadius: 18,
    backgroundColor: 'transparent',
  },
  scannerHint: {
    color: '#fff',
    fontSize: 16,
    marginTop: 24,
    textAlign: 'center',
    textShadowColor: '#000',
    textShadowRadius: 4,
  },
  scannerCancel: { marginTop: 'auto', alignSelf: 'stretch' },
});
