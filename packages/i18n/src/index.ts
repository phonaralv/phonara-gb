export const koMessages = {
  'app.web.phase0.title': 'PHONARA 기반 구축 중',
  'app.web.phase0.description': '마스터 플랜 기준으로 지갑, 보상, 거래, 게임, Admin을 안전하게 올릴 준비를 하고 있습니다.',
  'app.admin.phase0.title': 'Admin 운영 기반 구축 중',
  'app.admin.phase0.description': '예외 큐, 감사 로그, 권한 모델, 실시간 상담을 위한 기반을 준비하고 있습니다.',
} as const;

export const enMessages = {
  'app.web.phase0.title': 'PHONARA foundation in progress',
  'app.web.phase0.description': 'Preparing the safe base for wallet, rewards, trading, games, and Admin from the master plan.',
  'app.admin.phase0.title': 'Admin operations foundation in progress',
  'app.admin.phase0.description': 'Preparing exception queues, audit logs, roles, and live support foundations.',
} as const;

export type MessageKey = keyof typeof koMessages;
