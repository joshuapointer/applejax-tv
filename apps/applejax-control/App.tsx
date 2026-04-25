import { StatusBar } from 'expo-status-bar';
import * as DocumentPicker from 'expo-document-picker';
import { useCallback, useEffect, useRef, useState } from 'react';
import {
  Alert,
  KeyboardAvoidingView,
  Platform,
  Pressable,
  StyleSheet,
  Text,
  TextInput,
  View
} from 'react-native';
import { Buffer } from 'buffer';
import TcpSocket from 'react-native-tcp-socket';

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

  const socketRef = useRef<ReturnType<typeof TcpSocket.createConnection> | null>(null);
  const pausedRef = useRef(false);
  const rmsRef = useRef(0);
  const sentChunksRef = useRef(0);
  const droppedRef = useRef(0);

  // Subscribe to PCM events
  useEffect(() => {
    const pcmSub = AppleJaxAudio.addListener('pcm', ({ data, rms: r }) => {
      rmsRef.current = r;
      const sock = socketRef.current;
      if (!sock || pausedRef.current) {
        droppedRef.current += 1;
        return;
      }
      try {
        const payload = Buffer.from(data, 'base64');
        const frame = Buffer.alloc(HEADER_SIZE + payload.length);
        MAGIC.copy(frame, 0);
        frame.writeUInt32LE(payload.length, 4);
        payload.copy(frame, HEADER_SIZE);
        const ok = sock.write(frame as any);
        if (ok === false) pausedRef.current = true;
        sentChunksRef.current += 1;
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

  const connect = useCallback(() => {
    const portNum = parseInt(port, 10);
    if (!host || !portNum) {
      Alert.alert('Bad address', 'Enter host and port.');
      return;
    }
    setConn('connecting');
    setStatus(`Connecting to ${host}:${portNum}…`);
    const sock = TcpSocket.createConnection(
      { host, port: portNum, tls: false },
      () => {
        console.log(`[appleJax] connected to ${host}:${portNum}`);
        setConn('connected');
        setStatus(`Connected to ${host}:${portNum}`);
      }
    );
    sock.on('error', (err: Error) => {
      console.error('[appleJax] socket error:', err.message);
      setConn('error');
      setStatus(`Socket error: ${err.message}`);
      pausedRef.current = false;
      socketRef.current = null;
    });
    sock.on('close', () => {
      console.log('[appleJax] socket closed');
      setConn('disconnected');
      setStatus('Disconnected');
      pausedRef.current = false;
      socketRef.current = null;
    });
    sock.on('drain', () => {
      pausedRef.current = false;
    });
    socketRef.current = sock;
  }, [host, port]);

  const disconnect = useCallback(() => {
    socketRef.current?.destroy();
    socketRef.current = null;
    setConn('disconnected');
    setStatus('Disconnected');
  }, []);

  const startMic = useCallback(async () => {
    try {
      console.log('[appleJax] startMic called');
      await AppleJaxAudio.startMic();
      console.log('[appleJax] startMic resolved');
    } catch (e) {
      console.error('[appleJax] startMic error:', e);
      Alert.alert('Mic error', String(e));
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
      await AppleJaxAudio.playFile(asset.uri);
      console.log('[appleJax] playFile resolved');
    } catch (e) {
      console.error('[appleJax] playFile error:', e);
      Alert.alert('File error', String(e));
    }
  }, []);

  const stopFile = useCallback(async () => {
    try { await AppleJaxAudio.stopFile(); } catch {}
  }, []);

  const isStreaming = mode !== 'idle';
  const canStart = conn === 'connected' && !isStreaming;

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
        <Text style={styles.label}>tvOS host</Text>
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
        </View>
        <Pressable
          style={[styles.button, conn === 'connected' ? styles.buttonDanger : styles.buttonPrimary]}
          onPress={conn === 'connected' ? disconnect : connect}
        >
          <Text style={styles.buttonText}>
            {conn === 'connected' ? 'Disconnect' : conn === 'connecting' ? 'Connecting…' : 'Connect'}
          </Text>
        </Pressable>
      </View>

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
        <LevelMeter rmsRef={rmsRef} />
        <Text style={styles.meta}>
          22050 Hz · mono · 1024-frame chunks
        </Text>
      </View>
    </KeyboardAvoidingView>
  );
}

// Polls rmsRef at 20 Hz and only re-renders this small subtree, so the
// 21 Hz PCM event stream never re-renders the parent (which contains
// TextInput controls that drop keystrokes if re-rendered constantly).
function LevelMeter({ rmsRef }: { rmsRef: React.MutableRefObject<number> }) {
  const [width, setWidth] = useState(0);
  useEffect(() => {
    const id = setInterval(() => {
      setWidth(Math.min(100, Math.round(rmsRef.current * 400)));
    }, 50);
    return () => clearInterval(id);
  }, [rmsRef]);
  return (
    <View style={styles.meter}>
      <View style={[styles.meterFill, { width: `${width}%` }]} />
    </View>
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
  meta: { color: '#9aa', fontSize: 12 }
});
