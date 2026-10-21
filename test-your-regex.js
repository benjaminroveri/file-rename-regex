const http = require('node:http');
const fs = require('node:fs');
const path = require('node:path');
const { spawn } = require('node:child_process');

const htmlPath = path.join(__dirname, 'test-your-regex.html');
const samplesDirectory = path.join(__dirname, 'test-data', 'configs');
const renameScripts = {
  win32: path.join(__dirname, 'FileRenameRegex.ps1'),
  darwin: path.join(__dirname, 'file-rename-regex.sh'),
  linux: path.join(__dirname, 'file-rename-regex.sh')
};
const host = process.env.HOST || '127.0.0.1';
const port = Number(process.env.PORT) || 3000;
let selectedFolder = null;

function sendJson(response, status, data) {
  response.writeHead(status, { 'Content-Type': 'application/json; charset=utf-8' });
  response.end(JSON.stringify(data));
}

function readJson(request) {
  return new Promise((resolve, reject) => {
    let body = '';
    let tooLarge = false;
    request.setEncoding('utf8');
    request.on('data', (chunk) => {
      if (tooLarge) return;
      body += chunk;
      if (body.length > 1024 * 1024) {
        tooLarge = true;
        reject(new Error('Request body is too large.'));
      }
    });
    request.on('end', () => {
      if (tooLarge) return;
      try {
        resolve(JSON.parse(body));
      } catch {
        reject(new Error('Request body must be valid JSON.'));
      }
    });
    request.on('error', reject);
  });
}

function listSelectedFiles(order) {
  if (!selectedFolder) {
    throw new Error('Select a folder first.');
  }

  const files = fs.readdirSync(selectedFolder, { withFileTypes: true })
    .filter((entry) => entry.isFile())
    .map((entry) => {
      const filePath = path.join(selectedFolder, entry.name);
      const stats = fs.statSync(filePath);
      return { name: entry.name, modified: stats.mtimeMs, created: stats.birthtimeMs };
    });

  const selectors = {
    name: (file) => file.name,
    update: (file) => file.modified,
    create: (file) => file.created
  };
  const selector = selectors[order];
  if (!selector) {
    throw new Error('Order must be name, update, or create.');
  }
  files.sort((left, right) => {
    const comparison = typeof selector(left) === 'string'
      ? selector(left).localeCompare(selector(right))
      : selector(left) - selector(right);
    return comparison || left.name.localeCompare(right.name);
  });
  return files;
}

function runRename(order, inputs, response) {
  if (!selectedFolder) {
    sendJson(response, 400, { error: 'Select a folder first.' });
    return;
  }
  if (!['name', 'update', 'create'].includes(order)) {
    sendJson(response, 400, { error: 'Order must be name, update, or create.' });
    return;
  }
  if (!Array.isArray(inputs) || inputs.length === 0 || inputs.some((step) =>
    !step || typeof step.filter !== 'string' || typeof step.template !== 'string'
  )) {
    sendJson(response, 400, { error: 'At least one valid filter and template pair is required.' });
    return;
  }

  const scriptPath = renameScripts[process.platform];
  if (!scriptPath) {
    sendJson(response, 501, { error: `Renaming is not supported on ${process.platform}.` });
    return;
  }

  const pairs = inputs.flatMap(({ filter, template }) => [filter, template]);
  const args = process.platform === 'win32'
    ? ['-NoProfile', '-ExecutionPolicy', 'Bypass', '-File', scriptPath, `--order=${order}`, selectedFolder, ...pairs]
    : [scriptPath, `--order=${order}`, selectedFolder, ...pairs];
  const executable = process.platform === 'win32' ? 'powershell.exe' : 'bash';
  const child = spawn(executable, args, { windowsHide: true });
  let output = '';
  const appendOutput = (chunk) => {
    output += chunk.toString();
    if (output.length > 1024 * 1024) output = output.slice(-1024 * 1024);
  };
  child.stdout.on('data', appendOutput);
  child.stderr.on('data', appendOutput);
  child.on('error', (error) => {
    sendJson(response, 500, { error: `Unable to launch rename script: ${error.message}`, output });
  });
  child.on('close', (code) => {
    if (response.writableEnded) return;
    sendJson(response, code === 0 ? 200 : 500, { code, output });
  });
}

const server = http.createServer((request, response) => {
  const pathname = new URL(request.url, `http://${request.headers.host || host}`).pathname;

  if (pathname === '/api/folder') {
    if (request.method === 'POST') {
      readJson(request)
        .then((body) => {
          if (typeof body.folder !== 'string' || !body.folder.trim()) {
            throw new Error('Enter a folder path.');
          }
          return path.resolve(body.folder.trim());
        })
        .then((folder) => fs.promises.stat(folder).then((stats) => {
          if (!stats.isDirectory()) throw new Error('The selected path is not a folder.');
          selectedFolder = folder;
          sendJson(response, 200, { folder: selectedFolder });
        }))
        .catch((error) => sendJson(response, 400, { error: error.message }));
      return;
    }
    if (request.method === 'DELETE') {
      selectedFolder = null;
      sendJson(response, 200, { folder: null });
      return;
    }
    response.writeHead(405, { Allow: 'POST, DELETE' });
    response.end();
    return;
  }

  if (pathname === '/api/files') {
    if (request.method !== 'GET') {
      response.writeHead(405, { Allow: 'GET' });
      response.end();
      return;
    }
    try {
      const order = new URL(request.url, `http://${request.headers.host || host}`).searchParams.get('order') || 'name';
      sendJson(response, 200, listSelectedFiles(order));
    } catch (error) {
      sendJson(response, 400, { error: error.message });
    }
    return;
  }

  if (pathname === '/api/platform' && request.method === 'GET') {
    sendJson(response, 200, {
      script: renameScripts[process.platform] || '',
      windows: process.platform === 'win32'
    });
    return;
  }

  if (pathname === '/api/rename') {
    if (request.method !== 'POST') {
      response.writeHead(405, { Allow: 'POST' });
      response.end();
      return;
    }
    readJson(request).then(({ order, inputs }) => {
      runRename(order, inputs, response);
    }).catch((error) => {
      if (!response.writableEnded) sendJson(response, 400, { error: error.message });
    });
    return;
  }

  if (pathname === '/api/samples' || pathname.startsWith('/api/samples/')) {
    if (request.method !== 'GET') {
      response.writeHead(405, { Allow: 'GET', 'Content-Type': 'application/json; charset=utf-8' });
      response.end(JSON.stringify({ error: 'Method not allowed' }));
      return;
    }

    if (pathname === '/api/samples') {
      fs.readdir(samplesDirectory, (error, files) => {
        if (error) {
          console.error(error);
          sendJson(response, 500, { error: 'Unable to list samples' });
          return;
        }

        sendJson(response, 200, files.filter((file) => /^config-.*\.json$/i.test(file)).sort());
      });
      return;
    }

    let filename;
    try {
      filename = decodeURIComponent(pathname.slice('/api/samples/'.length));
    } catch {
      sendJson(response, 400, { error: 'Invalid sample filename' });
      return;
    }
    if (!/^config-.*\.json$/i.test(filename)) {
      sendJson(response, 404, { error: 'Sample not found' });
      return;
    }

    fs.readFile(path.join(samplesDirectory, filename), 'utf8', (error, contents) => {
      if (error) {
        sendJson(response, error.code === 'ENOENT' ? 404 : 500, { error: error.code === 'ENOENT' ? 'Sample not found' : 'Unable to read sample' });
        return;
      }

      try {
        sendJson(response, 200, JSON.parse(contents));
      } catch (parseError) {
        console.error(`Invalid JSON in ${filename}:`, parseError);
        sendJson(response, 500, { error: 'Sample contains invalid JSON' });
      }
    });
    return;
  }

  if (pathname !== '/' && pathname !== '/test-your-regex.html') {
    response.writeHead(404, { 'Content-Type': 'text/plain; charset=utf-8' });
    response.end('Not found');
    return;
  }

  if (request.method !== 'GET' && request.method !== 'HEAD') {
    response.writeHead(405, { Allow: 'GET, HEAD', 'Content-Type': 'text/plain; charset=utf-8' });
    response.end('Method not allowed');
    return;
  }

  fs.readFile(htmlPath, (error, html) => {
    if (error) {
      response.writeHead(500, { 'Content-Type': 'text/plain; charset=utf-8' });
      response.end('Unable to read test-your-regex.html');
      console.error(error);
      return;
    }

    response.writeHead(200, { 'Content-Type': 'text/html; charset=utf-8' });
    response.end(request.method === 'HEAD' ? undefined : html);
  });
});

server.listen(port, host, () => {
  console.log(`Serving test-your-regex.html at http://${host}:${port}`);
});
