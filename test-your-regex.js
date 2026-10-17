const http = require('node:http');
const fs = require('node:fs');
const path = require('node:path');

const htmlPath = path.join(__dirname, 'test-your-regex.html');
const samplesDirectory = __dirname;
const host = process.env.HOST || '127.0.0.1';
const port = Number(process.env.PORT) || 3000;

function sendJson(response, status, data) {
  response.writeHead(status, { 'Content-Type': 'application/json; charset=utf-8' });
  response.end(JSON.stringify(data));
}

const server = http.createServer((request, response) => {
  const pathname = new URL(request.url, `http://${request.headers.host || host}`).pathname;

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
