// One icon for each panel kind. The side bar buttons and the minimised buttons use this map.
// So the two cannot show different icons for the same panel.
import {
  Activity,
  Crosshair,
  Eye,
  Gauge,
  GitPullRequest,
  HeartPulse,
  Info,
  List,
  type LucideIcon,
  MessageCircleQuestionMark,
  MessageSquare,
  MessageSquareText,
  ScrollText,
  Settings,
  ShieldCheck,
  SlidersHorizontal,
} from 'lucide-react'
import type { PanelKind } from './state'

export const PANEL_ICONS: Record<PanelKind, LucideIcon> = {
  answer: MessageCircleQuestionMark,
  chat: MessageSquare,
  'daily-update': MessageSquareText,
  'event-log': ScrollText,
  overview: List,
  'overview-settings': SlidersHorizontal,
  performance: HeartPulse,
  reviews: GitPullRequest,
  'selected-item': Crosshair,
  'service-status': Activity,
  settings: Settings,
  'show-info': Info,
  trust: ShieldCheck,
  'usage-hud': Gauge,
  watchlist: Eye,
}
