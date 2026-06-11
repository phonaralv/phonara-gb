import { create } from 'zustand';
import { toast } from 'sonner';
import type { MessageKey } from '@phonara/i18n';

export type NotificationTone = 'success' | 'danger' | 'warning' | 'info';
export type PriceAlertDirection = 'above' | 'below';
export type BrowserNotificationPermission = NotificationPermission | 'unsupported';

export interface TradeNotification {
  id: string;
  tone: NotificationTone;
  title: string;
  body: string;
  createdAt: string;
}

export interface PriceAlertConfig {
  symbol: string;
  target: string;
  direction: PriceAlertDirection;
  enabled: boolean;
  triggered: boolean;
}

export interface EmitNotificationInput {
  id: string;
  tone: NotificationTone;
  title: string;
  body: string;
}

const NOTIFICATIONS_STORAGE_KEY = 'phonara.trade.notifications.v1';
const PRICE_ALERT_STORAGE_KEY = 'phonara.trade.priceAlert.v1';
const MAX_NOTIFICATIONS = 20;

/** Dedup baselines for realtime transitions — kept outside Zustand to avoid rerender churn. */
export const positionStatusRef = { current: new Map<string, string>() };
export const priceRef = { current: new Map<string, string>() };

function readStoredNotifications(): TradeNotification[] {
  if (typeof window === 'undefined') return [];
  try {
    const parsed = JSON.parse(window.localStorage.getItem(NOTIFICATIONS_STORAGE_KEY) ?? '[]') as unknown;
    if (!Array.isArray(parsed)) return [];
    return parsed.filter(isTradeNotification).slice(0, MAX_NOTIFICATIONS);
  } catch {
    return [];
  }
}

function readStoredPriceAlert(): PriceAlertConfig | null {
  if (typeof window === 'undefined') return null;
  try {
    const parsed = JSON.parse(window.localStorage.getItem(PRICE_ALERT_STORAGE_KEY) ?? 'null') as unknown;
    if (!parsed || typeof parsed !== 'object') return null;
    const alert = parsed as Partial<PriceAlertConfig>;
    if (
      typeof alert.symbol !== 'string' ||
      typeof alert.target !== 'string' ||
      (alert.direction !== 'above' && alert.direction !== 'below')
    ) {
      return null;
    }
    return {
      symbol: alert.symbol,
      target: alert.target,
      direction: alert.direction,
      enabled: alert.enabled === true,
      triggered: alert.triggered === true,
    };
  } catch {
    return null;
  }
}

function isTradeNotification(value: unknown): value is TradeNotification {
  if (!value || typeof value !== 'object') return false;
  const item = value as Partial<TradeNotification>;
  return (
    typeof item.id === 'string' &&
    typeof item.title === 'string' &&
    typeof item.body === 'string' &&
    typeof item.createdAt === 'string' &&
    (item.tone === 'success' || item.tone === 'danger' || item.tone === 'warning' || item.tone === 'info')
  );
}

function persistNotifications(items: TradeNotification[]): void {
  if (typeof window === 'undefined') return;
  window.localStorage.setItem(NOTIFICATIONS_STORAGE_KEY, JSON.stringify(items.slice(0, MAX_NOTIFICATIONS)));
}

function persistPriceAlert(alert: PriceAlertConfig | null): void {
  if (typeof window === 'undefined') return;
  if (!alert) {
    window.localStorage.removeItem(PRICE_ALERT_STORAGE_KEY);
    return;
  }
  window.localStorage.setItem(PRICE_ALERT_STORAGE_KEY, JSON.stringify(alert));
}

interface NotificationStore {
  notifications: TradeNotification[];
  priceAlert: PriceAlertConfig | null;
  permission: BrowserNotificationPermission;
  permissionBusy: boolean;
  permissionError: MessageKey | null;
  emitNotification: (input: EmitNotificationInput) => void;
  clearNotifications: () => void;
  setPriceAlert: (alert: PriceAlertConfig | null) => void;
  markPriceAlertTriggered: (symbol: string) => void;
  setPermission: (permission: BrowserNotificationPermission) => void;
  setPermissionBusy: (busy: boolean) => void;
  setPermissionError: (error: MessageKey | null) => void;
  seedPositionBaselines: (positions: ReadonlyArray<{ id: string; status: string }>) => void;
  resetBaselinesForUser: () => void;
}

export const useNotificationStore = create<NotificationStore>((set, get) => ({
  notifications: readStoredNotifications(),
  priceAlert: readStoredPriceAlert(),
  permission: typeof window !== 'undefined' && 'Notification' in window
    ? window.Notification.permission
    : 'unsupported',
  permissionBusy: false,
  permissionError: null,

  emitNotification: (input) => {
    const item: TradeNotification = {
      id: input.id,
      tone: input.tone,
      title: input.title,
      body: input.body,
      createdAt: new Date().toISOString(),
    };

    set((state) => {
      if (state.notifications.some((existing) => existing.id === item.id)) return state;
      const next = [item, ...state.notifications].slice(0, MAX_NOTIFICATIONS);
      persistNotifications(next);
      return { notifications: next };
    });

    const options = input.body ? { description: input.body, id: input.id } : { id: input.id };
    if (input.tone === 'danger') toast.error(input.title, options);
    else if (input.tone === 'success') toast.success(input.title, options);
    else if (input.tone === 'warning') toast.warning(input.title, options);
    else toast(input.title, options);

    const { permission } = get();
    if (permission === 'granted' && typeof window !== 'undefined' && 'Notification' in window) {
      try {
        new window.Notification(input.title, {
          body: input.body,
          tag: input.id,
          icon: '/pwa-192x192.png',
        });
      } catch {
        set({ permissionError: 'notif.permission.errorTitle' });
      }
    }
  },

  clearNotifications: () => {
    persistNotifications([]);
    set({ notifications: [] });
  },

  setPriceAlert: (alert) => {
    persistPriceAlert(alert);
    set({ priceAlert: alert });
  },

  markPriceAlertTriggered: (symbol) => {
    set((state) => {
      if (!state.priceAlert || state.priceAlert.symbol !== symbol) return state;
      const next = { ...state.priceAlert, triggered: true };
      persistPriceAlert(next);
      return { priceAlert: next };
    });
  },

  setPermission: (permission) => set({ permission }),
  setPermissionBusy: (permissionBusy) => set({ permissionBusy }),
  setPermissionError: (permissionError) => set({ permissionError }),

  seedPositionBaselines: (positions) => {
    positionStatusRef.current.clear();
    for (const position of positions) {
      positionStatusRef.current.set(position.id, position.status);
    }
  },

  resetBaselinesForUser: () => {
    positionStatusRef.current.clear();
    priceRef.current.clear();
  },
}));
