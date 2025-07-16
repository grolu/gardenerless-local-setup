const express = require('express');
const fs = require('fs');
const path = require('path');
const https = require('https');
const YAML = require('yaml');

const app = express();
const port = 3000;
app.use(express.json());
// allow cross-origin requests during development
app.use((req, res, next) => {
  res.set('Access-Control-Allow-Origin', '*');
  res.set('Access-Control-Allow-Headers', 'Content-Type, Authorization');
  res.set('Access-Control-Allow-Methods', 'GET,PUT,POST,DELETE,OPTIONS');
  if (req.method === 'OPTIONS') {
    res.sendStatus(200);
  } else {
    next();
  }
});
app.use(express.static(path.join(__dirname, 'dist')));

const kubeconfigPath = process.env.KUBECONFIG || path.join(__dirname, '..', 'kcp', '.kcp', 'admin.kubeconfig');
console.log('Loading kubeconfig from', kubeconfigPath);

function loadKubeconfig() {
  const content = fs.readFileSync(kubeconfigPath, 'utf8');
  const cfg = YAML.parse(content);
  const ctxName = cfg['current-context'] || cfg.contexts[0].name;
  const ctx = cfg.contexts.find(c => c.name === ctxName);
  const cluster = cfg.clusters.find(c => c.name === ctx.context.cluster);
  const user = cfg.users.find(u => u.name === ctx.context.user);
  const server = cluster.cluster.server;
  const caData = cluster.cluster['certificate-authority-data'];
  const caFile = cluster.cluster['certificate-authority'];
  const certData = user.user['client-certificate-data'];
  const certFile = user.user['client-certificate'];
  const keyData = user.user['client-key-data'];
  const keyFile = user.user['client-key'];
  const token = user.user.token;
  const ca = caData ? Buffer.from(caData, 'base64') : caFile ? fs.readFileSync(caFile) : undefined;
  const cert = certData ? Buffer.from(certData, 'base64') : certFile ? fs.readFileSync(certFile) : undefined;
  const key = keyData ? Buffer.from(keyData, 'base64') : keyFile ? fs.readFileSync(keyFile) : undefined;
  const headers = token ? { Authorization: `Bearer ${token}` } : {};
  return { server, ca, cert, key, headers };
}

const kubeconfig = loadKubeconfig();
console.log('API server:', kubeconfig.server);
const skipTlsEnv = process.env.SKIP_TLS_VERIFY;
// disable TLS verification by default unless explicitly set to "false"
const skipTlsVerify = skipTlsEnv !== 'false';
console.log('Skip TLS verification:', skipTlsVerify);

// also disable global TLS rejection when skipping verification to avoid any
// certificate errors from libraries that do not respect the agent option
if (skipTlsVerify) {
  process.env.NODE_TLS_REJECT_UNAUTHORIZED = '0';
}

const httpsAgent = new https.Agent({
  ca: kubeconfig.ca,
  cert: kubeconfig.cert,
  key: kubeconfig.key,
  rejectUnauthorized: skipTlsVerify ? false : !!kubeconfig.ca,
});

function buildPath(q) {
  let p = '';
  if (q.group && q.version) {
    p += `/apis/${q.group}/${q.version}`;
  } else {
    p += '/api/v1';
  }
  if (q.namespace) p += `/namespaces/${q.namespace}`;
  if (q.resource) p += `/${q.resource}`;
  if (q.name) p += `/${q.name}`;
  if (q.subresource) p += `/${q.subresource}`;
  return p;
}

app.get('/api/resource', async (req, res) => {
  const path = buildPath(req.query);
  console.log('[GET]', path);
  try {
    const response = await fetch(kubeconfig.server + path, {
      method: 'GET',
      headers: { Accept: 'application/yaml', ...kubeconfig.headers },
      agent: httpsAgent,
    });
    const text = await response.text();
    console.log('[GET]', path, '->', response.status);
    res.status(response.status).send(text);
  } catch (err) {
    console.error('GET error:', err);
    res.status(500).json({
      error: err.message,
      stack: err.stack,
    });
  }
});

app.put('/api/resource', async (req, res) => {
  const path = buildPath(req.query);
  console.log('[PUT]', path);
  const { yaml } = req.body;
  let obj;
  try {
    obj = YAML.parse(yaml);
  } catch (e) {
    res.status(400).json({ error: 'Invalid YAML: ' + e.message });
    return;
  }
  try {
    const response = await fetch(kubeconfig.server + path, {
      method: 'PUT',
      headers: { 'Content-Type': 'application/json', ...kubeconfig.headers },
      body: JSON.stringify(obj),
      agent: httpsAgent,
    });
    const text = await response.text();
    console.log('[PUT]', path, '->', response.status);
    res.status(response.status).send(text);
  } catch (err) {
    console.error('PUT error:', err);
    res.status(500).json({
      error: err.message,
      stack: err.stack,
    });
  }
});

app.patch('/api/resource', async (req, res) => {
  const path = buildPath(req.query);
  console.log('[PATCH]', path);
  const { yaml } = req.body;
  let obj;
  try {
    obj = YAML.parse(yaml);
  } catch (e) {
    res.status(400).json({ error: 'Invalid YAML: ' + e.message });
    return;
  }
  try {
    const response = await fetch(kubeconfig.server + path, {
      method: 'PATCH',
      headers: { 'Content-Type': 'application/merge-patch+json', ...kubeconfig.headers },
      body: JSON.stringify(obj),
      agent: httpsAgent,
    });
    const text = await response.text();
    console.log('[PATCH]', path, '->', response.status);
    res.status(response.status).send(text);
  } catch (err) {
    console.error('PATCH error:', err);
    res.status(500).json({
      error: err.message,
      stack: err.stack,
    });
  }
});

app.get('*', (req, res) => {
  res.sendFile(path.join(__dirname, 'dist', 'index.html'));
});

app.listen(port, () => {
  console.log(`server listening on ${port}`);
});
