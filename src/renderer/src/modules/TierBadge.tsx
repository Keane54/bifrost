// The tier badge of a module (Modules design 7): Standard or Permissive, in a box with padding.
// Settings > Modules and Heimdall's approval view show it.
import type { ModuleRow } from '../../../shared/modules'
import { cx } from '../lib/cx'
import { moduleTierLabel } from './ModuleRefresh'

const TONE: Record<ModuleRow['tier'], string> = {
  permissive: 'border-tier-permissive/45 text-tier-permissive',
  standard: 'border-tier-standard/40 text-tier-standard',
}

export function TierBadge({ tier }: { tier: ModuleRow['tier'] }): React.JSX.Element {
  return (
    <span
      className={cx(
        'shrink-0 border px-2.5 py-0.5 text-[10px] leading-tight whitespace-nowrap',
        TONE[tier],
      )}
      data-module-tier-badge={tier}
    >
      {moduleTierLabel(tier)}
    </span>
  )
}
