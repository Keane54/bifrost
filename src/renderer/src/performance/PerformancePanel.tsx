// The Performance panel (design section 5, mockup v4). A headline gives the health of Bifrost:
// OK, Warning or Problem. One Details row opens the sections below it: Bifrost, the Claude
// sessions, the Mac, the network, and the limits and disk.
import { ChevronRight } from 'lucide-react'
import { Fragment } from 'react'
import {
  type HealthState,
  type PerformanceSnapshot,
  PROC_GROUPS,
  type Reason,
} from '../../../shared/performance'
import { actionStateFor } from '../actions/action-model'
import { useActions } from '../actions/actions-context'
import { useRegistry } from '../data/registry'
import { cx } from '../lib/cx'
import {
  batteryText,
  gb,
  mb,
  ms,
  percent,
  pointsText,
  pressureText,
  rate,
  thermalText,
} from './format'
import TrendLine from './TrendLine'
import { usePerformance, usePerformanceDetails } from './use-performance'

type Snapshot = PerformanceSnapshot
type Mac = NonNullable<Snapshot['mac']>
type Network = NonNullable<Snapshot['network']>

const STATE_TEXT: Record<HealthState, string> = {
  ok: 'text-ctx-low',
  problem: 'text-ctx-high',
  warning: 'text-ctx-mid',
}
const STATE_LABEL: Record<HealthState, string> = {
  ok: 'OK',
  problem: 'Problem',
  warning: 'Warning',
}
// The small square in front of each reason has the colour of its level (user decision, 2026-11-09).
const REASON_SQUARE: Record<Reason['level'], string> = {
  problem: 'bg-ctx-high',
  warning: 'bg-ctx-mid',
}
const PRESSURE_TEXT: Record<NonNullable<Mac['pressure']>, string> = {
  critical: 'text-ctx-high',
  normal: 'text-ctx-low',
  warn: 'text-ctx-mid',
}
const PRESSURE_FILL: Record<NonNullable<Mac['pressure']>, string> = {
  critical: 'w-full',
  normal: 'w-1/3',
  warn: 'w-2/3',
}
const THERMAL_TEXT: Record<string, string> = {
  critical: 'text-ctx-high',
  nominal: 'text-ctx-low',
  serious: 'text-ctx-mid',
}
// An interface of the type "other" shows no name.
const LINK_TEXT: Partial<Record<NonNullable<Network['kind']>, string>> = {
  ethernet: 'Ethernet',
  vpn: 'VPN',
  wifi: 'Wi-Fi',
}
const KEY_VALUES = 'grid grid-cols-[130px_1fr] gap-y-0.5'

const orDash = <T,>(value: T | null, text: (v: T) => string): string =>
  value === null ? '-' : text(value)

function Headline({ snapshot }: { snapshot: Snapshot }): React.JSX.Element {
  // The Checking state shows with no sample, or with a sample older than 60 s. The headline never
  // says OK without data (design section 5.1).
  if (snapshot.state === 'ok' && snapshot.okText === null) {
    return (
      <div className='border-panel-edge border-b p-2 text-text-dim' data-perf-headline='checking'>
        Checking Bifrost…
      </div>
    )
  }
  return (
    <div className='border-panel-edge border-b p-2' data-perf-headline={snapshot.state}>
      <div
        className={cx('inline-flex items-center gap-1.5 font-semibold', STATE_TEXT[snapshot.state])}
      >
        <span aria-hidden={true} className='size-2 bg-current' />
        {STATE_LABEL[snapshot.state]}
      </div>
      {snapshot.state === 'ok' ? (
        <p className='mt-[3px] ml-3.5'>{snapshot.okText}</p>
      ) : (
        // Each reason is its own item, with a 6 px gap (user decision, 2026-11-09).
        <ul className='mt-1.5 flex flex-col gap-1.5' data-perf-reasons={true}>
          {snapshot.reasons.map(reason => (
            <li className='flex items-baseline gap-2 pl-0.5' key={`${reason.level}:${reason.text}`}>
              <span
                aria-hidden={true}
                className={cx('size-1 shrink-0 -translate-y-0.5', REASON_SQUARE[reason.level])}
              />
              {reason.text}
            </li>
          ))}
        </ul>
      )}
    </div>
  )
}

// The row has a bottom border only while it is open. A closed row ends flush with the panel
// edge, with no double line (user decision, 2026-11-09).
function DetailsRow({ open, onToggle }: { open: boolean; onToggle(): void }): React.JSX.Element {
  return (
    <button
      aria-expanded={open}
      className={cx(
        'flex w-full items-center gap-1.5 px-2 py-[5px] text-left text-text-dim hover:bg-hover hover:text-text active:bg-accent/12',
        open && 'border-panel-edge border-b',
      )}
      data-perf-details={true}
      onClick={onToggle}
      type='button'
    >
      <ChevronRight
        aria-hidden={true}
        className={cx('shrink-0 transition-transform duration-100', open && 'rotate-90')}
        size={12}
      />
      Details
    </button>
  )
}

function Section(props: {
  title: string
  right?: string
  rightClass?: string
  children: React.ReactNode
}): React.JSX.Element {
  return (
    <section className='border-panel-edge border-b px-2 py-1.5 last:border-b-0'>
      <h3 className='mb-1 flex gap-2 text-[11px] text-text-dim'>
        {props.title}
        {props.right !== undefined && (
          <span className={cx('ml-auto', props.rightClass ?? 'text-text')}>{props.right}</span>
        )}
      </h3>
      {props.children}
    </section>
  )
}

const NoData = (): React.JSX.Element => <p className='text-text-dim'>No data yet.</p>

function BifrostSection({ bifrost }: { bifrost: Snapshot['bifrost'] }): React.JSX.Element {
  if (bifrost === null) {
    return (
      <Section title='Bifrost'>
        <NoData />
      </Section>
    )
  }
  return (
    <Section right={`${mb(bifrost.ramMb)} · CPU ${percent(bifrost.cpu)}`} title='Bifrost'>
      <TrendLine trend={bifrost.trend} />
      <div className='grid grid-cols-[1fr_auto_auto] gap-x-3.5 gap-y-0.5'>
        {bifrost.groups.map(g => (
          <Fragment key={g.name}>
            {/* Only the group of the chat terminals shows its count (design section 5.2). */}
            <span>{g.name === PROC_GROUPS.terminals ? `${g.name} (${g.count})` : g.name}</span>
            <span className='text-right'>{mb(g.ramMb)}</span>
            <span className='text-right text-text-dim'>{percent(g.cpu)}</span>
          </Fragment>
        ))}
        <span className='text-text-dim'>Frame rate</span>
        <span className='text-right'>{orDash(bifrost.fps, v => `${Math.round(v)} fps`)}</span>
        <span />
        <span className='text-text-dim'>Main process delay</span>
        <span className='text-right'>{ms(bifrost.delayMs)}</span>
        <span />
      </div>
    </Section>
  )
}

// The heaviest sessions by RAM. Stop shows only for a session that Bifrost owns and that runs.
// It uses the Stop action with its checks and its confirmation (design section 5.4).
function SessionsSection({ sessions }: { sessions: Snapshot['sessions'] }): React.JSX.Element {
  const { rows } = useRegistry()
  const { contextFor, run } = useActions()
  if (sessions === null || sessions.top.length === 0) {
    return (
      <Section title='Claude sessions'>
        {sessions === null ? <NoData /> : <p className='text-text-dim'>No sessions are running.</p>}
      </Section>
    )
  }
  return (
    <Section right={`${mb(sessions.ramMb)} · CPU ${percent(sessions.cpu)}`} title='Claude sessions'>
      <div className='grid grid-cols-[1fr_auto_auto_auto] items-center gap-x-3 gap-y-0.5'>
        {sessions.top.map(session => {
          // The row comes from the registry by the session ID, never from a pid.
          const row = rows.find(r => r.sessionId === session.sessionId)
          const stop = actionStateFor('stop', row, contextFor(session.sessionId))
          const name = row?.name ?? session.name
          return (
            <Fragment key={session.sessionId}>
              <span className='min-w-0 truncate'>{name}</span>
              <span className='text-right'>{mb(session.ramMb)}</span>
              <span className='text-right text-text-dim'>{percent(session.cpu)}</span>
              <span className='flex justify-end'>
                {stop.enabled && (
                  <button
                    aria-label={`Stop ${name}`}
                    className='border border-panel-edge bg-black/35 px-1.5 text-text leading-4 hover:text-text-strong active:bg-accent/12'
                    data-perf-stop={session.sessionId}
                    onClick={() => run('stop', session.sessionId)}
                    type='button'
                  >
                    Stop
                  </button>
                )}
              </span>
            </Fragment>
          )
        })}
        {sessions.more.count > 0 && (
          <>
            <span className='text-text-dim'>{sessions.more.count} more</span>
            <span className='text-right text-text-dim'>{mb(sessions.more.ramMb)}</span>
            <span className='text-right text-text-dim'>{percent(sessions.more.cpu)}</span>
            <span />
          </>
        )}
      </div>
    </Section>
  )
}

function swapText(swap: Mac['swap']): string {
  if (swap === null) return '-'
  return swap.totalMb === 0 ? 'None' : `${mb(swap.usedMb)} of ${mb(swap.totalMb)}`
}

function MacSection({ mac }: { mac: Snapshot['mac'] }): React.JSX.Element {
  const pressure = mac?.pressure ?? null
  const thermal = mac?.thermal ?? null
  return (
    <Section title='Your Mac'>
      <dl className={KEY_VALUES}>
        <dt>Memory pressure</dt>
        <dd className={cx('flex items-center gap-2', pressure !== null && PRESSURE_TEXT[pressure])}>
          {pressure !== null && (
            <span aria-hidden={true} className='relative h-1.5 w-[110px] bg-panel-edge'>
              <span
                className={cx('absolute inset-y-0 left-0 bg-current', PRESSURE_FILL[pressure])}
              />
            </span>
          )}
          {pressureText(pressure)}
        </dd>
        <dt>Swap</dt>
        <dd>{swapText(mac?.swap ?? null)}</dd>
        <dt>CPU load</dt>
        <dd>{orDash(mac?.cpuLoad ?? null, percent)}</dd>
        <dt>Thermal state</dt>
        <dd className={cx(thermal !== null && THERMAL_TEXT[thermal])}>{thermalText(thermal)}</dd>
        <dt>Battery</dt>
        <dd>{batteryText(mac?.battery ?? null)}</dd>
      </dl>
    </Section>
  )
}

function NetworkSection({ network }: { network: Snapshot['network'] }): React.JSX.Element {
  const link = network?.kind ? LINK_TEXT[network.kind] : undefined
  const state =
    network === null
      ? undefined
      : [network.online ? 'Online' : 'Offline', link].filter(Boolean).join(' · ')
  const down = orDash(network?.downBps ?? null, rate)
  const up = orDash(network?.upBps ?? null, rate)
  return (
    <Section
      right={state}
      rightClass={network?.online ? 'text-ctx-low' : 'text-ctx-high'}
      title='Network'
    >
      <dl className={KEY_VALUES}>
        <dt>Down / up</dt>
        <dd className='flex gap-3'>
          <span>↓ {down}</span>
          <span>↑ {up}</span>
        </dd>
        <dt>Anthropic</dt>
        <dd>{ms(network?.anthropicMs ?? null)}</dd>
        <dt>GitHub</dt>
        <dd>{ms(network?.githubMs ?? null)}</dd>
      </dl>
    </Section>
  )
}

function LimitsSection({ limits }: { limits: Snapshot['limits'] }): React.JSX.Element {
  return (
    <Section title='Limits and disk'>
      <dl className={KEY_VALUES}>
        <dt>GitHub points</dt>
        <dd>{pointsText(limits.github)}</dd>
        <dt>Free disk</dt>
        <dd>{gb(limits.freeDiskGb)}</dd>
        {/* The size of the Reviews clones shows only when Reviews has clones. */}
        {limits.clonesMb !== null && (
          <>
            <dt>Reviews clones</dt>
            <dd>{mb(limits.clonesMb)}</dd>
          </>
        )}
      </dl>
    </Section>
  )
}

export default function PerformancePanel(): React.JSX.Element {
  const snapshot = usePerformance()
  const details = usePerformanceDetails()
  return (
    <div className='text-text text-xs' data-performance={snapshot.state}>
      <Headline snapshot={snapshot} />
      <DetailsRow onToggle={() => details.setOpen(!details.open)} open={details.open} />
      {details.open && (
        <div data-perf-sections={true}>
          <BifrostSection bifrost={snapshot.bifrost} />
          <SessionsSection sessions={snapshot.sessions} />
          <MacSection mac={snapshot.mac} />
          <NetworkSection network={snapshot.network} />
          <LimitsSection limits={snapshot.limits} />
        </div>
      )}
    </div>
  )
}
