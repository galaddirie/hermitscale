#!/usr/bin/python3 -I
"""Deterministic local Responses fixture; never forwards a request or uses a key."""
import json
import threading
from pathlib import Path
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer

MESSAGE = {'id': 'msg_fixture', 'type': 'message', 'role': 'assistant', 'status': 'completed', 'content': [{'type': 'output_text', 'text': 'Synthetic Codex gateway fixture completed.', 'annotations': []}]}
RESPONSE = {'id': 'resp_fixture', 'object': 'response', 'created_at': 1, 'status': 'completed', 'model': 'gpt-5.4', 'output': [MESSAGE], 'usage': {'input_tokens': 1, 'output_tokens': 1, 'total_tokens': 2, 'input_tokens_details': {'cached_tokens': 0}, 'output_tokens_details': {'reasoning_tokens': 0}}}


ROUTES_LOCK = threading.Lock()


def record_route(metadata):
    path = Path('/workspace/preview-data/fixture-routes.json')
    with ROUTES_LOCK:
        prior = json.loads(path.read_text()) if path.exists() else []
        prior.append(metadata)
        path.write_text(json.dumps(prior))
        return len(prior)


class Handler(BaseHTTPRequestHandler):
    protocol_version = 'HTTP/1.1'

    def log_message(self, *_arguments):
        pass

    def do_GET(self):
        # Host gateway intentionally exposes Responses POST only.
        record_route({'method': 'GET', 'path': self.path, 'admitted': False})
        self.send_response(404)
        self.send_header('Content-Length', '0')
        self.end_headers()

    def do_POST(self):
        if self.path != '/v1/responses':
            self.send_error(404)
            return
        # Bound and consume the synthetic input; do not log or retain its content.
        length = int(self.headers.get('Content-Length', '0'))
        if length > 2_000_000:
            self.send_error(413)
            return
        payload = json.loads(self.rfile.read(length))
        tools=payload.get('tools',[])
        output=payload.get('max_output_tokens',8192)
        def external(value):
            if isinstance(value,dict): return value.get('type') in ('input_image','input_file','input_audio','input_video','item_reference') or any(external(v) for v in value.values())
            if isinstance(value,list): return any(external(v) for v in value)
            return False
        def client_tool(tool):
            return isinstance(tool, dict) and tool.get('type') in ('function', 'custom')
        def supported_tool(tool):
            if client_tool(tool):
                return True
            if not isinstance(tool, dict) or tool.get('type') != 'namespace':
                return False
            children = tool.get('tools')
            return isinstance(tool.get('name'), str) and 1 <= len(tool['name'].encode()) <= 128 and isinstance(children, list) and 1 <= len(children) <= 128 and all(client_tool(child) for child in children)
        accepted = (length <= 1048576 and isinstance(output, int) and output > 0 and isinstance(tools, list) and len(tools) <= 128 and all(supported_tool(tool) for tool in tools) and payload.get('previous_response_id') is None and payload.get('conversation') is None and not external(payload.get('input')))
        sequence = record_route({'method': 'POST', 'path': self.path, 'keys': sorted(payload.keys()), 'tool_types': sorted({t.get('type', 'unknown') for t in tools}), 'bytes': length, 'admitted': accepted, 'dummy_authorization': self.headers.get('Authorization') in ('Bearer synthetic-local-token', 'Bearer synthetic-local-token-renewed'), 'renewed_dummy_authorization': self.headers.get('Authorization') == 'Bearer synthetic-local-token-renewed'})
        if not accepted:
            body = json.dumps({'error': {'type': 'invalid_request_error', 'message': 'Host gateway admission rejected fixture request'}}).encode()
            self.send_response(400)
            self.send_header('Content-Type', 'application/json')
            self.send_header('Content-Length', str(len(body)))
            self.end_headers()
            self.wfile.write(body)
            return
        message = dict(MESSAGE, id='msg_fixture_' + str(sequence))
        response = dict(RESPONSE, id='resp_fixture_' + str(sequence), output=[message])
        item_id = message['id']
        events = [
            ('response.created', {'response': dict(response, status='in_progress', output=[])}),
            ('response.output_item.added', {'output_index': 0, 'item': dict(message, status='in_progress', content=[])}),
            ('response.content_part.added', {'item_id': item_id, 'output_index': 0, 'content_index': 0, 'part': {'type': 'output_text', 'text': '', 'annotations': []}}),
            ('response.output_text.delta', {'item_id': item_id, 'output_index': 0, 'content_index': 0, 'delta': message['content'][0]['text']}),
            ('response.output_text.done', {'item_id': item_id, 'output_index': 0, 'content_index': 0, 'text': message['content'][0]['text']}),
            ('response.content_part.done', {'item_id': item_id, 'output_index': 0, 'content_index': 0, 'part': message['content'][0]}),
            ('response.output_item.done', {'output_index': 0, 'item': message}),
            ('response.completed', {'response': response}),
        ]
        body = ''.join('event: ' + kind + '\ndata: ' + json.dumps(dict(payload, type=kind, sequence_number=index)) + '\n\n' for index, (kind, payload) in enumerate(events)).encode()
        self.send_response(200)
        self.send_header('Content-Type', 'text/event-stream')
        self.send_header('Content-Length', str(len(body)))
        self.end_headers()
        self.wfile.write(body)


if __name__ == '__main__':
    ThreadingHTTPServer(('127.0.0.1', 8091), Handler).serve_forever()
