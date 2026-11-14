// The sandbox probe. It runs in a module frame and sends each result to the Bifrost page.
// The query gives the ports of the local test servers. Each probe must fail.
// No probe calls an API that reads or writes the clipboard when it works. The clipboard
// probes read the policy and the permission state. The copy probe has no selection, so a copy
// that works writes nothing.
;(() => {
  const params = new URLSearchParams(location.search)
  const port = params.get('http')
  const remote = `http://127.0.0.1:${port}`
  const violations = []
  document.addEventListener('securitypolicyviolation', e => {
    violations.push({ blockedURI: e.blockedURI, directive: e.effectiveDirective })
  })
  let copyEvents = 0
  document.addEventListener('copy', () => {
    copyEvents += 1
  })
  const send = msg => parent.postMessage({ host: location.host, ...msg }, '*')
  const err = e => `${e?.name ?? 'Error'}: ${e?.message ?? String(e)}`
  const wait = (ms, value) => new Promise(r => setTimeout(() => r(value), ms))
  const settle = (p, ms = 3000) => Promise.race([p, wait(ms, { timeout: true })])

  async function media(constraints) {
    if (!navigator.mediaDevices) return { error: 'no mediaDevices', outcome: 'blocked' }
    try {
      const s = await settle(navigator.mediaDevices.getUserMedia(constraints))
      if (s?.getTracks) for (const t of s.getTracks()) t.stop()
      return { outcome: s?.getTracks ? 'allowed' : 'timeout' }
    } catch (e) {
      return { error: err(e), outcome: 'blocked' }
    }
  }

  async function notifications() {
    if (typeof Notification === 'undefined') return { error: 'no Notification', outcome: 'blocked' }
    try {
      const result = await settle(Notification.requestPermission())
      return { outcome: result === 'granted' ? 'allowed' : 'blocked', result }
    } catch (e) {
      return { error: err(e), outcome: 'blocked' }
    }
  }

  async function topLocation(path) {
    try {
      top.location.href = `${remote}/${path}`
      await wait(500)
      return { outcome: 'no error (see the top URL)' }
    } catch (e) {
      return { error: err(e), outcome: 'blocked' }
    }
  }

  function windowOpen(path) {
    try {
      const w = window.open(`${remote}/${path}`)
      return { outcome: w ? 'allowed' : 'blocked' }
    } catch (e) {
      return { error: err(e), outcome: 'blocked' }
    }
  }

  const probes = {
    bifrostApi() {
      let parentApi = 'readable'
      try {
        void parent.bifrost
      } catch (e) {
        parentApi = err(e)
      }
      const none =
        typeof window.bifrost === 'undefined' &&
        typeof window.require === 'undefined' &&
        typeof window.process === 'undefined' &&
        parentApi !== 'readable'
      return { outcome: none ? 'blocked' : 'allowed', parentApi }
    },
    camera: () => media({ video: true }),
    async clipboardPermission() {
      const states = {}
      for (const name of ['clipboard-read', 'clipboard-write']) {
        try {
          states[name] = (await navigator.permissions.query({ name })).state
        } catch (e) {
          states[name] = err(e)
        }
      }
      const granted = Object.values(states).includes('granted')
      return { outcome: granted ? 'allowed' : 'blocked', states }
    },
    clipboardPolicy() {
      const policy = document.featurePolicy ?? document.permissionsPolicy
      if (!policy) return { outcome: 'no policy API' }
      const read = policy.allowsFeature('clipboard-read')
      const write = policy.allowsFeature('clipboard-write')
      return { outcome: read || write ? 'allowed' : 'blocked', read, write }
    },
    context() {
      return { origin: self.origin, outcome: 'info', secure: window.isSecureContext }
    },
    crossModuleScript() {
      return new Promise(resolve => {
        const s = document.createElement('script')
        s.src = 'bifrost-module://probe-two/panels/esm.js'
        s.onload = () => resolve({ outcome: 'allowed' })
        s.onerror = () => resolve({ outcome: 'blocked' })
        document.head.append(s)
      })
    },
    cssImage() {
      const d = document.createElement('div')
      d.style.cssText = `width:4px;height:4px;background-image:url(${remote}/css.png)`
      document.body.append(d)
      return wait(800, { outcome: 'see the hits' })
    },
    eventSource() {
      return new Promise(resolve => {
        try {
          const es = new EventSource(`${remote}/sse`)
          es.onopen = () => {
            es.close()
            resolve({ outcome: 'allowed' })
          }
          es.onerror = () => {
            es.close()
            resolve({ outcome: 'blocked' })
          }
        } catch (e) {
          resolve({ error: err(e), outcome: 'blocked' })
        }
      })
    },
    async fetchOwnFile() {
      try {
        await fetch('probe.html')
        return { outcome: 'allowed' }
      } catch (e) {
        return { error: err(e), outcome: 'blocked' }
      }
    },
    async fetchRemote() {
      try {
        await fetch(`${remote}/fetch`)
        return { outcome: 'allowed' }
      } catch (e) {
        return { error: err(e), outcome: 'blocked' }
      }
    },
    linkHints() {
      for (const [rel, href] of [
        ['preconnect', `${remote}/`],
        ['prefetch', `${remote}/prefetch`],
      ]) {
        const l = document.createElement('link')
        l.rel = rel
        l.href = href
        document.head.append(l)
      }
      return wait(1000, { outcome: 'see the hits' })
    },
    microphone: () => media({ audio: true }),
    notifications,
    parentDocument() {
      try {
        return { outcome: 'allowed', title: parent.document.title }
      } catch (e) {
        return { error: err(e), outcome: 'blocked' }
      }
    },
    remoteImage() {
      return new Promise(resolve => {
        const img = new Image()
        img.onload = () => resolve({ outcome: 'allowed' })
        img.onerror = () => resolve({ outcome: 'blocked' })
        img.src = `${remote}/img.png`
        document.body.append(img)
      })
    },
    topLocation: () => topLocation('top'),
    async webrtc() {
      if (typeof RTCPeerConnection === 'undefined') {
        return { error: 'no RTCPeerConnection', outcome: 'blocked' }
      }
      try {
        const pc = new RTCPeerConnection({
          iceServers: [
            { urls: `stun:127.0.0.1:${params.get('udp')}` },
            {
              credential: 'c',
              urls: `turn:127.0.0.1:${params.get('tcp')}?transport=tcp`,
              username: 'u',
            },
          ],
        })
        const candidates = []
        pc.onicecandidate = e => {
          if (e.candidate) candidates.push(e.candidate.type ?? 'unknown')
        }
        pc.createDataChannel('x')
        await pc.setLocalDescription(await pc.createOffer())
        await wait(3000)
        pc.close()
        return { candidates, outcome: 'see the hits' }
      } catch (e) {
        return { error: err(e), outcome: 'blocked' }
      }
    },
    webSocket() {
      return new Promise(resolve => {
        try {
          const ws = new WebSocket(`ws://127.0.0.1:${port}/ws`)
          ws.onopen = () => resolve({ outcome: 'allowed' })
          ws.onerror = () => resolve({ outcome: 'blocked' })
        } catch (e) {
          resolve({ error: err(e), outcome: 'blocked' })
        }
      })
    },
    windowOpen: () => windowOpen('popup'),
    xhr() {
      return new Promise(resolve => {
        try {
          const x = new XMLHttpRequest()
          x.open('GET', `${remote}/xhr`)
          x.onload = () => resolve({ outcome: 'allowed' })
          x.onerror = () => resolve({ outcome: 'blocked' })
          x.send()
        } catch (e) {
          resolve({ error: err(e), outcome: 'blocked' })
        }
      })
    },
  }

  // These probes run in a click handler, so the frame has a user activation. The copy probes
  // run first, in the same task as the click. ORDER gives the run order.
  const ORDER = [
    'execCommandCopy',
    'queryCopy',
    'queryPaste',
    'windowOpen',
    'topLocation',
    'notifications',
    'camera',
  ]
  const gesture = {
    camera: () => media({ audio: true, video: true }),
    execCommandCopy() {
      getSelection().removeAllRanges()
      const before = copyEvents
      try {
        const returned = document.execCommand('copy')
        return { copyEvents: copyEvents - before, outcome: returned ? 'allowed' : 'blocked' }
      } catch (e) {
        return { error: err(e), outcome: 'blocked' }
      }
    },
    notifications,
    queryCopy() {
      const range = document.createRange()
      range.selectNodeContents(document.getElementById('who'))
      getSelection().removeAllRanges()
      getSelection().addRange(range)
      const enabled = document.queryCommandEnabled('copy')
      getSelection().removeAllRanges()
      return { outcome: enabled ? 'allowed' : 'blocked' }
    },
    queryPaste() {
      return { outcome: document.queryCommandEnabled('paste') ? 'allowed' : 'blocked' }
    },
    topLocation: () => topLocation('top-gesture'),
    windowOpen: () => windowOpen('popup-gesture'),
  }

  const button = document.createElement('button')
  button.id = 'gesture'
  button.textContent = 'gesture'
  button.addEventListener('click', async () => {
    const results = { activation: navigator.userActivation?.isActive ?? null }
    for (const name of ORDER) {
      try {
        results[name] = await gesture[name]()
      } catch (e) {
        results[name] = { error: err(e), outcome: 'probe error' }
      }
    }
    send({ results, type: 'gesture', violations })
  })
  document.body.append(button)

  // More probes (fix round 1). Each one runs from a real click on its own button.
  function anchor(href, download) {
    const a = document.createElement('a')
    a.href = href
    if (download) a.download = download
    document.body.append(a)
    a.click()
    a.remove()
  }
  const clicks = {
    appScheme: () => anchor('bifrost-probe-app://open'),
    downloadBlob: () => anchor(URL.createObjectURL(new Blob(['probe'])), 'probe.txt'),
    downloadOwn: () => anchor('probe.js', 'probe.js'),
    mailto: () => anchor('mailto:probe@bifrost-probe.test'),
  }
  for (const [name, run] of Object.entries(clicks)) {
    const b = document.createElement('button')
    b.id = name
    b.textContent = name
    b.addEventListener('click', async () => {
      let error = null
      try {
        run()
      } catch (e) {
        error = err(e)
      }
      await wait(800)
      send({ error, name, type: 'click', url: location.href })
    })
    document.body.append(b)
  }

  // A file input. The test cancels a file chooser at once and never picks a file.
  const file = document.createElement('input')
  file.type = 'file'
  file.id = 'file'
  file.addEventListener('change', () => {
    send({ files: [...file.files].map(f => f.name), type: 'file-change' })
  })
  file.addEventListener('cancel', () => send({ type: 'file-cancel' }))
  document.body.append(file)

  // A drop zone that takes a dropped file and reads it.
  const zone = document.createElement('div')
  zone.id = 'drop'
  zone.textContent = 'drop'
  zone.style.cssText = 'width:200px;height:40px;background:#ddd'
  zone.addEventListener('dragover', e => e.preventDefault())
  zone.addEventListener('drop', async e => {
    e.preventDefault()
    const files = []
    for (const f of e.dataTransfer?.files ?? []) {
      let read = null
      try {
        read = (await f.text()).length
      } catch (x) {
        read = err(x)
      }
      files.push({ name: f.name, read, size: f.size })
    }
    send({ files, type: 'drop', types: [...(e.dataTransfer?.types ?? [])] })
  })
  document.body.append(zone)

  // Each command tries to move a frame or to send a form.
  const commands = {
    anchorBlank() {
      const a = document.createElement('a')
      a.href = `${remote}/anchor-blank`
      a.target = '_blank'
      document.body.append(a)
      a.click()
    },
    anchorTop() {
      const a = document.createElement('a')
      a.href = `${remote}/anchor-top`
      a.target = '_top'
      document.body.append(a)
      a.click()
    },
    // Name hints that the script adds after load. The test reads the net log for a DNS job for
    // msg.host (dns-prefetch and preconnect) and msg.anchor (an anchor the browser may prefetch).
    dnsHints(msg) {
      for (const [rel, href] of [
        ['dns-prefetch', `//${msg.host}`],
        ['preconnect', `http://${msg.host}/`],
      ]) {
        const l = document.createElement('link')
        l.rel = rel
        l.href = href
        document.head.append(l)
      }
      const a = document.createElement('a')
      a.href = `http://${msg.anchor}/page`
      a.textContent = 'link'
      document.body.append(a)
      const img = new Image()
      img.src = `http://${msg.host}/i.png`
      document.body.append(img)
    },
    form() {
      const f = document.createElement('form')
      f.method = 'post'
      f.action = `${remote}/form`
      const i = document.createElement('input')
      i.name = 'secret'
      i.value = 'x'
      f.append(i)
      document.body.append(f)
      f.submit()
    },
    historyBack() {
      history.back()
    },
    navBlob() {
      const b = new Blob(['<p>blob</p>'], { type: 'text/html' })
      location.href = URL.createObjectURL(b)
    },
    navData() {
      location.href = 'data:text/html,<p>data</p>'
    },
    navJavascript() {
      location.href = 'javascript:void(0)'
    },
    navOtherModule() {
      location.href = `bifrost-module://probe-two/panels/probe.html${location.search}`
    },
    navRemote() {
      location.href = `${remote}/nav`
    },
    navSameModule() {
      location.href = `bifrost-module://${location.host}/panels/probe.html${location.search}&x=1`
    },
  }

  window.addEventListener('message', async e => {
    const msg = e.data ?? {}
    if (msg.cmd === 'ping') {
      send({ fromParent: e.source === parent, id: msg.id, origin: e.origin, type: 'pong' })
    } else if (msg.cmd === 'probes') {
      const results = {}
      for (const name of Object.keys(probes)) {
        try {
          results[name] = await probes[name]()
        } catch (x) {
          results[name] = { error: err(x), outcome: 'probe error' }
        }
      }
      await wait(300)
      send({ id: msg.id, results, type: 'probes', violations })
    } else if (msg.cmd in commands) {
      try {
        commands[msg.cmd](msg)
      } catch (x) {
        send({ cmd: msg.cmd, error: err(x), id: msg.id, type: 'threw' })
      }
      await wait(800)
      send({ cmd: msg.cmd, id: msg.id, type: 'after', url: location.href })
    }
  })

  send({ type: 'ready', url: location.href })
})()
