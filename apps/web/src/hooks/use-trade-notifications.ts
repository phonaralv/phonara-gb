import { useCallback } from 'react';
import { useQuery, useQueryClient } from '@tanstack/react-query';
import Decimal from 'decimal.js';
import { useAuth } from '../contexts/auth-context';
import { env } from '../lib/env';
import { useT } from '../lib/i18n';
import { supabase } from '../lib/supabase';
import { translateError } from '../lib/translate-error';
import {
  useNotificationStore,
  type PriceAlertConfig,
  type TradeNotification,
} from '../stores/notifications';

export type { PriceAlertConfig, TradeNotification };

function isPositiveDecimal(value: string): boolean {
  try {
    const decimal = new Decimal(value);
    return decimal.isFinite() && decimal.gt(0);
  } catch {
    return false;
  }
}

function vapidKeyToArrayBuffer(value: string): ArrayBuffer {
  const padding = '='.repeat((4 - (value.length % 4)) % 4);
  const base64 = (value + padding).replace(/-/g, '+').replace(/_/g, '/');
  const raw = window.atob(base64);
  const buffer = new ArrayBuffer(raw.length);
  const output = new Uint8Array(buffer);
  for (let i = 0; i < raw.length; i += 1) output[i] = raw.charCodeAt(i);
  return buffer;
}

/** Trade-route UI bindings over the global notification store. Realtime lives in __root. */
export function useTradeNotifications() {
  const t = useT();
  const { session } = useAuth();
  const userId = session?.user.id ?? null;
  const qc = useQueryClient();
  const notifications = useNotificationStore((s) => s.notifications);
  const priceAlert = useNotificationStore((s) => s.priceAlert);
  const permission = useNotificationStore((s) => s.permission);
  const permissionBusy = useNotificationStore((s) => s.permissionBusy);
  const permissionError = useNotificationStore((s) => s.permissionError);
  const emitNotification = useNotificationStore((s) => s.emitNotification);
  const clearNotifications = useNotificationStore((s) => s.clearNotifications);
  const setPriceAlertState = useNotificationStore((s) => s.setPriceAlert);
  const setPermission = useNotificationStore((s) => s.setPermission);
  const setPermissionBusy = useNotificationStore((s) => s.setPermissionBusy);
  const setPermissionError = useNotificationStore((s) => s.setPermissionError);

  const pushConsentKey = ['push-notification-consent', userId] as const;
  const { data: pushConsent = false } = useQuery({
    queryKey: pushConsentKey,
    queryFn: async () => {
      const { data } = await supabase
        .from('user_consents')
        .select('accepted')
        .eq('user_id', userId!)
        .eq('doc_type', 'push_notification')
        .order('accepted_at', { ascending: false })
        .limit(1)
        .maybeSingle();
      return data?.accepted === true;
    },
    enabled: !!userId,
    staleTime: 60_000,
  });

  const setPriceAlert = useCallback((next: Omit<PriceAlertConfig, 'enabled' | 'triggered'>) => {
    if (!next.symbol || !isPositiveDecimal(next.target)) {
      emitNotification({
        id: `price-alert-invalid:${Date.now()}`,
        tone: 'warning',
        title: t('notif.priceAlert.invalidTitle'),
        body: t('notif.priceAlert.invalidBody'),
      });
      return false;
    }
    setPriceAlertState({ ...next, enabled: true, triggered: false });
    emitNotification({
      id: `price-alert-set:${next.symbol}:${next.direction}:${next.target}:${Date.now()}`,
      tone: 'info',
      title: t('notif.priceAlert.savedTitle'),
      body: t('notif.priceAlert.savedBody', { symbol: next.symbol, target: next.target }),
    });
    return true;
  }, [emitNotification, setPriceAlertState, t]);

  const clearPriceAlert = useCallback(() => {
    setPriceAlertState(null);
  }, [setPriceAlertState]);

  const requestBrowserNotifications = useCallback(async () => {
    if (!userId) return false;
    if (typeof window === 'undefined' || !('Notification' in window)) {
      setPermission('unsupported');
      setPermissionError('notif.permission.unsupported');
      return false;
    }

    setPermissionBusy(true);
    setPermissionError(null);
    try {
      const nextPermission = await window.Notification.requestPermission();
      setPermission(nextPermission);
      const accepted = nextPermission === 'granted';
      const { error } = await supabase.rpc('rpc_record_consent', {
        p_doc_type: 'push_notification',
        p_doc_version: '1.0',
        p_accepted: accepted,
        p_ip_address: undefined,
        p_user_agent: window.navigator.userAgent,
        p_locale: window.navigator.language.startsWith('ko') ? 'ko' : 'en',
      });
      if (error) throw error;
      await qc.invalidateQueries({ queryKey: pushConsentKey });

      if (accepted && env.VITE_VAPID_PUBLIC_KEY && 'serviceWorker' in navigator && 'PushManager' in window) {
        const registration = await navigator.serviceWorker.ready;
        const existing = await registration.pushManager.getSubscription();
        const subscription = existing ?? await registration.pushManager.subscribe({
          userVisibleOnly: true,
          applicationServerKey: vapidKeyToArrayBuffer(env.VITE_VAPID_PUBLIC_KEY),
        });
        const json = subscription.toJSON();
        const { error: subError } = await supabase.from('push_subscriptions').upsert({
          user_id: userId,
          endpoint: subscription.endpoint,
          p256dh: json.keys?.['p256dh'] ?? '',
          auth: json.keys?.['auth'] ?? '',
          ua: window.navigator.userAgent,
        }, { onConflict: 'user_id,endpoint' });
        if (subError) throw subError;
      }

      emitNotification({
        id: `browser-permission:${nextPermission}:${Date.now()}`,
        tone: accepted ? 'success' : 'warning',
        title: accepted ? t('notif.permission.enabledTitle') : t('notif.permission.deniedTitle'),
        body: accepted ? t('notif.permission.enabledBody') : t('notif.permission.deniedBody'),
      });
      return accepted;
    } catch (err) {
      const key = translateError(err);
      setPermissionError(key);
      emitNotification({
        id: `browser-permission-error:${Date.now()}`,
        tone: 'danger',
        title: t('notif.permission.errorTitle'),
        body: t(key),
      });
      return false;
    } finally {
      setPermissionBusy(false);
    }
  }, [
    emitNotification,
    pushConsentKey,
    qc,
    setPermission,
    setPermissionBusy,
    setPermissionError,
    t,
    userId,
  ]);

  return {
    notifications,
    permission,
    permissionBusy,
    permissionError,
    pushConsent,
    priceAlert,
    clearNotifications,
    requestBrowserNotifications,
    setPriceAlert,
    clearPriceAlert,
  };
}
