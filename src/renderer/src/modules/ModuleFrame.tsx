// The frame of one module panel (Modules design 8.1). The module page runs in a sandboxed frame
// with only allow-scripts (an opaque origin), from the module protocol. The frame talks to Heimdall
// only through the bridge.
import { type ReactElement, type RefObject, useEffect, useRef } from 'react'
import { moduleUrl } from '../../../shared/module-url'
import { cx } from '../lib/cx'
import { connectFrame } from './bridge'

export interface ModuleFrameProps {
  moduleId: string
  panelId: string
  // The HTML entry of the panel in the manifest, for example "panels/main.html".
  entry: string
}

// The frame element. Its key holds the module, the panel and the entry, so a change of any of
// them gives a new frame element with a new browsing context. The page of the old module can then
// never post as the new module.
export function moduleFrameElement(
  { entry, moduleId, panelId }: ModuleFrameProps,
  ref: RefObject<HTMLIFrameElement | null>,
): ReactElement {
  return (
    <iframe
      className={cx('block h-full w-full border-0 bg-transparent')}
      data-module-panel={panelId}
      key={JSON.stringify([moduleId, panelId, entry])}
      ref={ref}
      sandbox='allow-scripts'
      src={moduleUrl(moduleId, entry)}
      title={`Module panel ${panelId}`}
    />
  )
}

export function ModuleFrame(props: ModuleFrameProps) {
  const frame = useRef<HTMLIFrameElement>(null)
  const { entry, moduleId, panelId } = props

  // One connection for each frame element. A new key gives a new element, and this effect runs
  // again for it.
  // biome-ignore lint/correctness/useExhaustiveDependencies: panelId and entry are in the key
  useEffect(() => {
    const element = frame.current
    if (element === null) return
    return connectFrame(element, moduleId, {
      host: window,
      modules: window.bifrost.modules,
      now: () => Date.now(),
    })
  }, [moduleId, panelId, entry])

  return moduleFrameElement(props, frame)
}
