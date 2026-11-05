import { useRegistry } from '../data/registry'

const LABEL = 'text-text-dim'

// The last two parts of the path, as the Project column shows it (spec 8.3).
function project(cwd: string): string {
  return cwd.split('/').filter(Boolean).slice(-2).join('/') || cwd
}

// A temporary view of the selected session. The Selected Item of M3 replaces it.
export default function SelectedItemPanel(): React.JSX.Element {
  const { rows, selectedId } = useRegistry()
  const row = selectedId === null ? undefined : rows.find(r => r.sessionId === selectedId)

  if (!row) return <div className='p-3 text-[13px] text-text-dim'>No session selected.</div>
  return (
    <dl className='grid select-text grid-cols-[auto_1fr] gap-x-3 gap-y-1 p-3 text-[13px]'>
      <dt className={LABEL}>Name</dt>
      <dd className='truncate'>{row.name}</dd>
      <dt className={LABEL}>State</dt>
      <dd>{row.state}</dd>
      <dt className={LABEL}>Kind</dt>
      <dd>{row.kind}</dd>
      <dt className={LABEL}>Project</dt>
      <dd className='truncate' title={row.cwd}>
        {project(row.cwd)}
      </dd>
    </dl>
  )
}
