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
import dgram from 'react-native-udp';
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

  // UDP transport: each PCM chunk is fired as a single datagram. Backpressure
  // can't head-of-line block later audio (unlike TCP) — kernel either accepts
  // the datagram or drops it, with at most a single ~46 ms glitch on loss.
  // No queue, no `'drain'` handshake, no reconnect choreography.
  const udpSocketRef = useRef<ReturnType<typeof dgram.createSocket> | null>(null);
  const targetRef = useRef<{ host: string; port: number } | null>(null);
  const rmsRef = useRef(0);
  const sentChunksRef = useRef(0);
  const droppedRef = useRef(0);

  // Lazily create the UDP socket on first use; keep it for the app lifetime.
  // We never close it on "disconnect" — we just clear targetRef so PCM events
  // become no-ops.
  const ensureSocket = useCallback(() => {
    if (udpSocketRef.current) return udpSocketRef.current;
    const sock = dgram.createSocket({ type: 'udp4' });
    sock.on('error', (err: Error) => {
      console.warn('[appleJax] udp socket error:', err.message);
    });
    sock.bind(0); // ephemeral local port
    udpSocketRef.current = sock;
    return sock;
  }, []);

  // Subscribe to PCM events
  useEffect(() => {
    const pcmSub = AppleJaxAudio.addListener('pcm', ({ data, rms: r }) => {
      rmsRef.current = r;
      const target = targetRef.current;
      if (!target) {
        droppedRef.current += 1;
        return;
      }
      try {
        const payload = Buffer.from(data, 'base64');
        // sampleCount is the count of Float32 samples (mono). The TV-side
        // header reads this as a uint32_le so it can validate the trailing
        // payload size = sampleCount * 4 bytes.
        const sampleCount = (payload.length / 4) | 0;
        const datagram = Buffer.alloc(HEADER_SIZE + payload.length);
        MAGIC.copy(datagram, 0);
        datagram.writeUInt32LE(sampleCount, 4);
        payload.copy(datagram, HEADER_SIZE);
        const sock = ensureSocket();
        sock.send(datagram, 0, datagram.length, target.port, target.host, (err: Error | null) => {
          if (err) {
            droppedRef.current += 1;
            // Throttle: only the first send error per ~1000 attempts to avoid log spam.
            if (sentChunksRef.current % 1000 === 0) {
              console.warn('[appleJax] udp send error:', err.message);
            }
          }
        });
        sentChunksRef.current += 1;
      } catch (e) {
        console.warn('[appleJax] pcm send error:', e);
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

  // "Connect" is just setting the destination — UDP needs no handshake. We open
  // (or reuse) the local socket so the first PCM event has somewhere to go, and
  // mark conn='connected' optimistically. The TV-side derives client-connected
  // state from packet-arrival recency, so the user experience stays the same.
  const connectTo = useCallback((targetHost: string, targetPort: string) => {
    const portNum = parseInt(targetPort, 10);
    if (!targetHost || !portNum) {
      Alert.alert('Bad address', 'Enter host and port.');
      return;
    }
    ensureSocket();
    targetRef.current = { host: targetHost, port: portNum };
    setConn('connected');
    setStatus(`Streaming to ${targetHost}:${portNum} (UDP)`);
  }, [ensureSocket]);

  const connect = useCallback(() => {
    connectTo(host, port);
  }, [connectTo, host, port]);

  const disconnect = useCallback(() => {
    targetRef.current = null;
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
        <LevelMeter rmsRef={rmsRef} droppedRef={droppedRef} />
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
}: {
  rmsRef: React.MutableRefObject<number>;
  droppedRef: React.MutableRefObject<number>;
}) {
  const [display, setDisplay] = useState({ width: 0, dropped: 0 });
  useEffect(() => {
    const id = setInterval(() => {
      setDisplay({
        width: Math.min(100, Math.round(rmsRef.current * 400)),
        dropped: droppedRef.current,
      });
    }, 50);
    return () => clearInterval(id);
  }, [rmsRef, droppedRef]);
  return (
    <>
      <View style={styles.meter}>
        <View style={[styles.meterFill, { width: `${display.width}%` }]} />
      </View>
      <Text style={styles.meta}>
        22050 Hz · mono · 1024-frame chunks · UDP
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
