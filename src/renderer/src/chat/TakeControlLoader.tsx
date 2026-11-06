// The Take control loader of a chat window (spec 9.2). It shows while Take control runs, and until
// the terminal shows Claude. The chat panel hides the terminal during that time, so the window
// shows the normal panel background and the line. The bottom two fifths show a soft rainbow of
// the app icon colours that shifts slowly. With reduced motion, the rainbow does not move.
import { useRegistry } from '../data/registry'
import { loaderText } from './loader'

export default function TakeControlLoader({ sessionId }: { sessionId: string }): React.JSX.Element {
  const { rows } = useRegistry()
  const name = rows.find(row => row.sessionId === sessionId)?.name ?? null
  return (
    <div
      className='pointer-events-none absolute inset-0 z-20 overflow-hidden'
      data-take-control-loader={sessionId}
    >
      <p
        className='absolute inset-x-0 top-[40%] px-4 text-center text-[13px] text-text'
        role='status'
      >
        {loaderText(name)}
      </p>
      <div className='loader-rainbow absolute inset-x-0 bottom-0 h-2/5 animate-loader-shift opacity-25 motion-reduce:animate-none' />
    </div>
  )
}
