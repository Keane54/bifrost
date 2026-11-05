// The shared parts of the menus and the tooltips.
import { Tooltip } from '@base-ui/react/tooltip'

export const MENU_POPUP =
  'min-w-36 border border-panel-edge bg-title py-1 text-text text-xs outline-none backdrop-blur-md'
// The highlight of an item stays neutral. A press on an item that is not disabled gives a short
// cyan tint (spec 8.10). The tint has the data-highlighted variant first, so that its CSS rule
// comes after the rule of the highlight. A pressed item always has the highlight.
export const MENU_ITEM =
  'flex h-5 cursor-default select-none items-center gap-2 px-2 outline-none data-disabled:opacity-40 data-highlighted:bg-text-strong/10 data-highlighted:not-data-disabled:active:bg-accent/12'
export const MENU_SEPARATOR = 'my-1 h-px bg-panel-edge'

// A tooltip on one element. A null label shows no tooltip.
// A line break in the label starts a new line in the tooltip.
// The tooltip closes when the pointer leaves the element. The pointer goes through the tooltip.
// So a tooltip that covers the next element does not stop the tooltip of that element.
// A menu entry puts its tooltip at the right. Then the tooltip does not cover the next entry.
export function Tip({
  label,
  side = 'top',
  children,
}: {
  label: string | null
  side?: 'top' | 'right'
  children: React.ReactElement
}): React.JSX.Element {
  return (
    <Tooltip.Root disabled={label === null} disableHoverablePopup={true}>
      <Tooltip.Trigger render={children} />
      <Tooltip.Portal>
        <Tooltip.Positioner className='pointer-events-none z-50' side={side} sideOffset={6}>
          <Tooltip.Popup className='whitespace-pre-line border border-panel-edge bg-title px-2 py-1 text-text text-xs'>
            {label}
          </Tooltip.Popup>
        </Tooltip.Positioner>
      </Tooltip.Portal>
    </Tooltip.Root>
  )
}
