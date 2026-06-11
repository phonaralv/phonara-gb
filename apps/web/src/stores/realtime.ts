import { create } from 'zustand';
import type { RealtimeConnectionStatus } from '../hooks/use-realtime';

type RealtimeChannelKey = 'positions' | 'oraclePrices';

const DISCONNECTED_STATUSES = new Set<RealtimeConnectionStatus>(['closed', 'channel_error', 'timed_out']);

interface RealtimeConnectionStore {
  statuses: Partial<Record<RealtimeChannelKey, RealtimeConnectionStatus>>;
  disconnected: boolean;
  setStatus: (key: RealtimeChannelKey, status: RealtimeConnectionStatus) => void;
}

function isDisconnected(statuses: Partial<Record<RealtimeChannelKey, RealtimeConnectionStatus>>): boolean {
  return Object.values(statuses).some((status) => status !== undefined && DISCONNECTED_STATUSES.has(status));
}

export const useRealtimeConnectionStore = create<RealtimeConnectionStore>((set) => ({
  statuses: {},
  disconnected: false,
  setStatus: (key, status) => set((state) => {
    const statuses = { ...state.statuses, [key]: status };
    return { statuses, disconnected: isDisconnected(statuses) };
  }),
}));
