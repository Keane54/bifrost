// One icon for each panel kind. The side bar buttons and the minimised buttons use this map.
// So the two cannot show different icons for the same panel.
import {
  Activity,
  Crosshair,
  Eye,
  FilePen,
  Gauge,
  GitPullRequest,
  HeartPulse,
  Info,
  List,
  type LucideIcon,
  MessageCircleQuestionMark,
  MessageSquare,
  MessageSquareText,
  Puzzle,
  ScrollText,
  Settings,
  Shield,
  ShieldCheck,
  SlidersHorizontal,
} from 'lucide-react'
import type { PanelKind } from './state'

export const PANEL_ICONS: Record<PanelKind, LucideIcon> = {
  answer: MessageCircleQuestionMark,
  chat: MessageSquare,
  'daily-update': MessageSquareText,
  'event-log': ScrollText,
  heimdall: Shield,
  // A module panel shows the icon of its manifest. This icon is for a module that is gone.
  module: Puzzle,
  overview: List,
  'overview-settings': SlidersHorizontal,
  performance: HeartPulse,
  'review-draft': FilePen,
  reviews: GitPullRequest,
  'selected-item': Crosshair,
  'service-status': Activity,
  settings: Settings,
  'show-info': Info,
  trust: ShieldCheck,
  'usage-hud': Gauge,
  watchlist: Eye,
}
