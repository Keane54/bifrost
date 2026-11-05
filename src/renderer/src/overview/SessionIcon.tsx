// The row icon (spec 8.3). The glyph shows the kind of the session. Its colour shows the project.
// The yellow box and the red box are four corner brackets around the glyph.
import { Hexagon, SquareTerminal } from 'lucide-react'
import type { SessionRow } from '../../../shared/types'
import { cx } from '../lib/cx'
import { useTerminalIcon } from '../lib/use-terminal-icon'
import { iconKind, projectColourIndex, projectKey } from './session-icon'

// Tailwind finds only full class names in the source. So this lookup holds full names.
// The index is the project colour minus 1.
const PROJECT_TEXT: string[] = [
  'text-project-1',
  'text-project-2',
  'text-project-3',
  'text-project-4',
  'text-project-5',
  'text-project-6',
  'text-project-7',
  'text-project-8',
]

const KIND_TITLE = {
  external: 'External session',
  owned: 'Owned session',
  parked: 'Parked session',
}

// Each bracket is one corner of a square. The two borders of the corner make the L shape.
const CORNERS = [
  'top-0 left-0 border-t-2 border-l-2',
  'top-0 right-0 border-t-2 border-r-2',
  'bottom-0 left-0 border-b-2 border-l-2',
  'bottom-0 right-0 border-b-2 border-r-2',
]

// The side is size px. Each arm of a bracket is 30% of the side.
// An external row with a known terminal app shows the icon of the app (D7). While the icon
// loads, and for an app without an icon, the row shows the terminal glyph.
export function SessionIcon({ row, size }: { row: SessionRow; size: number }): React.JSX.Element {
  const kind = iconKind(row)
  const appIcon = useTerminalIcon(row)
  const Glyph = kind === 'external' ? SquareTerminal : Hexagon
  const colour =
    kind === 'parked' ? 'text-parked' : PROJECT_TEXT[projectColourIndex(projectKey(row.cwd)) - 1]
  const arm = `${size * 0.3}px`
  const glyphSize = Math.round((size * 2) / 3)
  return (
    <span
      className='relative inline-flex shrink-0 items-center justify-center'
      style={{ height: size, width: size }}
      title={KIND_TITLE[kind]}
    >
      {kind === 'external' && appIcon !== null ? (
        <img
          alt=''
          data-terminal-icon={row.terminalApp}
          draggable={false}
          height={glyphSize}
          src={appIcon}
          title={row.terminalApp}
          width={glyphSize}
        />
      ) : (
        <Glyph aria-hidden={true} className={colour} size={glyphSize} />
      )}
      {row.box !== 'none' &&
        CORNERS.map(corner => (
          <span
            aria-hidden={true}
            className={cx(
              'absolute',
              corner,
              row.box === 'yellow' ? 'border-box-yellow' : 'border-box-red',
              row.flashing && 'animate-box-flash',
            )}
            key={corner}
            style={{ height: arm, width: arm }}
          />
        ))}
    </span>
  )
}
