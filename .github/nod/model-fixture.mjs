import { createServer } from 'node:http';

const model = { id: 'fixture-model', object: 'model', owned_by: 'fixture' };
createServer((req, res) => {
  if (req.method === 'GET' && req.url === '/v1/models') {
    res.writeHead(200, { 'content-type': 'application/json' });
    res.end(JSON.stringify({ object: 'list', data: [model] }));
    return;
  }
  if (req.method !== 'POST' || req.url !== '/v1/chat/completions') {
    res.writeHead(404).end();
    return;
  }
  let body = '';
  req.on('data', (chunk) => { body += chunk; });
  req.on('end', () => {
    const input = JSON.parse(body);
    const base = { id: 'fixture', object: 'chat.completion.chunk', created: 1, model: model.id };
    if (input.stream) {
      res.writeHead(200, { 'content-type': 'text/event-stream' });
      for (const choice of [
        { index: 0, delta: { role: 'assistant', content: 'fixture reply' }, finish_reason: null },
        { index: 0, delta: {}, finish_reason: 'stop' },
      ]) res.write(`data: ${JSON.stringify({ ...base, choices: [choice] })}\n\n`);
      res.end('data: [DONE]\n\n');
    } else {
      res.writeHead(200, { 'content-type': 'application/json' });
      res.end(JSON.stringify({ ...base, object: 'chat.completion', choices: [{ index: 0, message: { role: 'assistant', content: 'fixture reply' }, finish_reason: 'stop' }], usage: { prompt_tokens: 1, completion_tokens: 1, total_tokens: 2 } }));
    }
  });
}).listen(8080, '0.0.0.0');
