// The checkbox of Bifrost (spec 8.10, 9.1). Do not use the native checkbox. Chromium on macOS
// draws it with round corners and a colour of the system, not a token colour.
// The checkbox is the box and its name. A click on the name also changes the box.
// The box is small, square and dark, with a check mark. A disabled box is faded (spec 9.1).
import { Checkbox } from '@base-ui/react/checkbox'
import { Check } from 'lucide-react'
import type { Ref } from 'react'

const CHECKBOX =
  'group flex min-w-0 flex-1 items-center gap-2 not-data-disabled:active:bg-accent/12'
const BOX =
  'flex size-3.5 shrink-0 items-center justify-center border border-text-dim bg-bg text-text-strong group-data-checked:border-text group-data-disabled:opacity-40'

export function CheckBox(props: {
  checked: boolean
  disabled?: boolean
  label: string
  // The accessible name when it differs from the label, for example the name of a settings row.
  ariaLabel?: string
  onChange(checked: boolean): void
  ref?: Ref<HTMLElement>
}): React.JSX.Element {
  return (
    <Checkbox.Root
      aria-label={props.ariaLabel}
      checked={props.checked}
      className={CHECKBOX}
      disabled={props.disabled}
      onCheckedChange={checked => props.onChange(checked)}
      ref={props.ref}
    >
      <span className={BOX}>
        <Checkbox.Indicator className='flex data-unchecked:hidden'>
          <Check aria-hidden={true} size={10} strokeWidth={3} />
        </Checkbox.Indicator>
      </span>
      <span className='truncate'>{props.label}</span>
    </Checkbox.Root>
  )
}
