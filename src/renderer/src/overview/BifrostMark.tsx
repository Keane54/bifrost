// The mark of a session that Bifrost started or controls.
// This is a placeholder until the Bifrost logo exists. The logo replaces only this component.
import { Hexagon } from 'lucide-react'

export function BifrostMark({
  className,
  size,
}: {
  className?: string
  size?: number
}): React.JSX.Element {
  return <Hexagon aria-hidden={true} className={className} size={size} />
}
