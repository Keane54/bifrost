import type * as os from 'node:os'
import { expect, test, vi } from 'vitest'
import type { ExecFn } from '../../../src/main/claude/cli'
import {
  cpuLoad,
  cpuPercent,
  linkKind,
  parseBattery,
  parseDefaultInterface,
  parseDuKb,
  parseHardwarePorts,
  parseNetBytes,
  parsePressureLevel,
  parsePsStats,
  parseSwap,
  readBattery,
  readDuKb,
  readLink,
  readNetBytes,
  readPressure,
  readPsStats,
  readSwap,
  treeSum,
} from '../../../src/main/performance/system'

const ps = [
  '    1     0  24048  39:29.00 /sbin/launchd',
  '  274     1  50944   1:02:03 /Applications/Example App.app/Contents/MacOS/Example App',
  '  275   274   7792 2-03:04:05 /usr/libexec/helper',
  'bad line',
].join('\n')

test('parsePsStats reads the three time formats and a comm with spaces', () => {
  const table = parsePsStats(ps)
  expect(table.size).toBe(3)
  expect(table.get(1)).toEqual({ cpuSeconds: 39 * 60 + 29, pid: 1, ppid: 0, rssKb: 24048 })
  expect(table.get(274)?.cpuSeconds).toBe(3723)
  expect(table.get(275)?.cpuSeconds).toBe(2 * 86400 + 3 * 3600 + 4 * 60 + 5)
})

test('treeSum sums a root, its children and a grandchild, and ignores a sibling', () => {
  const row = (pid: number, ppid: number, rssKb: number, cpuSeconds: number) =>
    [pid, { cpuSeconds, pid, ppid, rssKb }] as const
  const table = new Map([
    row(10, 1, 100, 1),
    row(11, 10, 200, 2),
    row(12, 10, 300, 3),
    row(13, 11, 400, 4),
    row(20, 1, 999, 9),
  ])
  const sum = treeSum(table, 10)
  expect(sum.rssKb).toBe(1000)
  expect(sum.cpuSeconds).toBe(10)
  expect([...sum.pids].sort()).toEqual([10, 11, 12, 13])
  expect(treeSum(table, 99)).toEqual({ cpuSeconds: 0, pids: [], rssKb: 0 })
})

test('cpuPercent gives percent of one core and never goes below 0', () => {
  expect(cpuPercent(10, 13, 2000)).toBe(150)
  expect(cpuPercent(13, 10, 2000)).toBe(0)
  expect(cpuPercent(1, 2, 0)).toBe(0)
})

test('parsePressureLevel maps 1, 2 and 4', () => {
  expect(parsePressureLevel('1\n')).toBe('normal')
  expect(parsePressureLevel('2\n')).toBe('warn')
  expect(parsePressureLevel('4\n')).toBe('critical')
  expect(parsePressureLevel('')).toBeNull()
  expect(parsePressureLevel('3')).toBeNull()
})

test('parseSwap reads used and total in MB', () => {
  expect(parseSwap('total = 6144.00M  used = 4605.06M  free = 1538.94M  (encrypted)')).toEqual({
    totalMb: 6144,
    usedMb: 4605,
  })
  expect(parseSwap('nonsense')).toBeNull()
})

test('parseBattery reads charging, discharging and a desktop', () => {
  expect(
    parseBattery(
      "Now drawing from 'AC Power'\n -InternalBattery-0 (id=1)\t82%; charging; 1:10 remaining present: true\n",
    ),
  ).toEqual({ charging: true, onBattery: false, percent: 82 })
  expect(
    parseBattery(
      "Now drawing from 'Battery Power'\n -InternalBattery-0 (id=1)\t64%; discharging; 3:05 remaining present: true\n",
    ),
  ).toEqual({ charging: false, onBattery: true, percent: 64 })
  expect(
    parseBattery(
      "Now drawing from 'AC Power'\n -InternalBattery-0 (id=1)\t100%; charged; 0:00 remaining present: true\n",
    ),
  ).toEqual({ charging: false, onBattery: false, percent: 100 })
  expect(parseBattery("Now drawing from 'AC Power'\n")).toBeNull()
})

const route = [
  '   route to: default',
  'destination: default',
  '    gateway: 192.168.1.1',
  '  interface: en0',
  '      flags: <UP,GATEWAY,DONE,STATIC,PRCLONING,GLOBAL>',
].join('\n')

const hardware = [
  'Hardware Port: Wi-Fi',
  'Device: en0',
  'Ethernet Address: aa:bb:cc:dd:ee:01',
  '',
  'Hardware Port: Thunderbolt Bridge',
  'Device: bridge0',
  'Ethernet Address: aa:bb:cc:dd:ee:02',
  '',
  'Hardware Port: USB 10/100/1000 LAN',
  'Device: en5',
  'Ethernet Address: aa:bb:cc:dd:ee:03',
  '',
  'Hardware Port: Ethernet Adapter (en4)',
  'Device: en4',
  'Ethernet Address: aa:bb:cc:dd:ee:04',
  '',
  'VLAN Configurations',
  '===================',
].join('\n')

test('parseDefaultInterface finds en0', () => {
  expect(parseDefaultInterface(route)).toBe('en0')
  expect(parseDefaultInterface('no interface here')).toBeNull()
})

test('parseHardwarePorts and linkKind classify the links', () => {
  const ports = parseHardwarePorts(hardware)
  expect(ports.get('en0')).toBe('Wi-Fi')
  expect(ports.size).toBe(4)
  expect(linkKind('utun3', ports)).toBe('vpn')
  expect(linkKind('ipsec0', ports)).toBe('vpn')
  expect(linkKind('en0', ports)).toBe('wifi')
  expect(linkKind('bridge0', ports)).toBe('ethernet')
  expect(linkKind('en4', ports)).toBe('ethernet')
  expect(linkKind('en5', ports)).toBe('other')
  expect(linkKind('en9', ports)).toBe('other')
})

const netstat = [
  'Name       Mtu   Network       Address            Ipkts Ierrs     Ibytes    Opkts Oerrs     Obytes  Coll',
  'lo0        16384 <Link#1>                       5610467     0 26388186710  5610467     0 26388186710     0',
  'en0        1500  <Link#14>   aa:bb:cc:dd:ee:01  8000000     0  9000000000  4000000     0  1200000000     -',
  'en0        1500  192.168.1     192.168.1.20     8000000     -  9000000000  4000000     -  1200000000     -',
].join('\n')

test('parseNetBytes picks the Link row of the device', () => {
  expect(parseNetBytes(netstat, 'en0')).toEqual({ inBytes: 9000000000, outBytes: 1200000000 })
  expect(parseNetBytes(netstat, 'lo0')).toEqual({ inBytes: 26388186710, outBytes: 26388186710 })
  expect(parseNetBytes(netstat, 'en7')).toBeNull()
})

test('cpuLoad gives 25 for one busy core of four', () => {
  const core = (user: number, idle: number) =>
    ({ model: '', speed: 0, times: { idle, irq: 0, nice: 0, sys: 0, user } }) as os.CpuInfo
  const prev = [core(0, 0), core(0, 0), core(0, 0), core(0, 0)]
  const next = [core(100, 0), core(0, 100), core(0, 100), core(0, 100)]
  expect(cpuLoad(prev, next)).toBe(25)
  expect(cpuLoad(prev, prev)).toBe(0)
  expect(cpuLoad([], [])).toBe(0)
})

test('parseDuKb reads the size in KB', () => {
  expect(parseDuKb('12345\t/some/path\n')).toBe(12345)
  expect(parseDuKb('0\t/tmp')).toBe(0)
  expect(parseDuKb('')).toBeNull()
})

const ok = (stdout: string): ExecFn => vi.fn<ExecFn>(async () => ({ code: 0, stderr: '', stdout }))
const failed: ExecFn = vi.fn<ExecFn>(async () => ({ code: 1, stderr: 'x', stdout: 'junk' }))
const empty = ok('')
const thrower: ExecFn = vi.fn<ExecFn>(async () => {
  throw new Error('boom')
})

test('each reader gives null for code 1, for empty output and for a throw', async () => {
  for (const exec of [failed, empty, thrower]) {
    expect(await readPsStats(exec)).toBeNull()
    expect(await readPressure(exec)).toBeNull()
    expect(await readSwap(exec)).toBeNull()
    expect(await readBattery(exec)).toBeNull()
    expect(await readLink(exec)).toBeNull()
    expect(await readNetBytes(exec, 'en0')).toBeNull()
    expect(await readDuKb(exec, '/tmp/x')).toBeNull()
  }
})

test('the readers parse good output with the absolute commands', async () => {
  const calls: string[] = []
  const exec: ExecFn = async (file, args) => {
    calls.push(file)
    const out: Record<string, string> = {
      '/bin/ps': ps,
      '/sbin/route': route,
      '/usr/bin/du': '77\t/tmp/x\n',
      '/usr/bin/pmset': "Now drawing from 'AC Power'\n -InternalBattery-0\t50%; charging\n",
      '/usr/sbin/netstat': netstat,
      '/usr/sbin/networksetup': hardware,
      '/usr/sbin/sysctl': args.includes('vm.swapusage')
        ? 'total = 1024.00M  used = 512.00M  free = 512.00M'
        : '4\n',
    }
    return { code: 0, stderr: '', stdout: out[file] ?? '' }
  }
  expect((await readPsStats(exec))?.size).toBe(3)
  expect(await readPressure(exec)).toBe('critical')
  expect(await readSwap(exec)).toEqual({ totalMb: 1024, usedMb: 512 })
  expect((await readBattery(exec))?.percent).toBe(50)
  expect(await readLink(exec)).toEqual({ device: 'en0', kind: 'wifi' })
  expect(await readNetBytes(exec, 'en0')).toEqual({ inBytes: 9000000000, outBytes: 1200000000 })
  expect(await readDuKb(exec, '/tmp/x')).toBe(77)
  expect(calls.every(c => c.startsWith('/'))).toBe(true)
})
