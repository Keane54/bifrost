// The changes that Install of Live details makes, as a numbered list (spec 11.1, D10).
import type { LiveStatus } from '../../../shared/types'
import { liveSteps } from './live-notice'

export default function LiveSteps({ status }: { status: LiveStatus }): React.JSX.Element {
  return (
    <ol className='select-text list-decimal space-y-1 pl-5' data-live-steps={true}>
      {liveSteps(status).map(step => (
        <li key={step}>{step}</li>
      ))}
    </ol>
  )
}
