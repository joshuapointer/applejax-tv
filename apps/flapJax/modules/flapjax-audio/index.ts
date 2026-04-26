import { NativeModule, requireNativeModule } from 'expo';

export type FlapJaxAudioEvents = {
  pcm: (params: { data: string; rms: number; frames: number }) => void;
  state: (params: { state: 'idle' | 'mic' | 'file'; error?: string }) => void;
};

declare class FlapJaxAudioModuleType extends NativeModule<FlapJaxAudioEvents> {
  startMic(): Promise<void>;
  stopMic(): Promise<void>;
  playFile(uri: string): Promise<void>;
  stopFile(): Promise<void>;
  readonly sampleRate: number;
  readonly channels: number;
  readonly framesPerChunk: number;
}

export default requireNativeModule<FlapJaxAudioModuleType>('FlapJaxAudioModule');
