// An ES module script. It shows that a module frame can load its own module scripts.
parent.postMessage({ host: location.host, type: 'esm-ran' }, '*')
