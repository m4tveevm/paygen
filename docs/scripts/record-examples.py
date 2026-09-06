#!/usr/bin/env python3
"""Render captured, verified CLI output as terminal GIFs; never invent a run."""
import argparse
import hashlib
import json
from pathlib import Path
import textwrap
from PIL import Image, ImageDraw, ImageFont

parser = argparse.ArgumentParser(description=__doc__)
parser.add_argument('evidence', type=Path, help='Successful tmp/docs-examples/run.* directory')
parser.add_argument('--output', type=Path, required=True, help='New output directory')
parser.add_argument('--font', type=Path, default=Path('/usr/share/fonts/truetype/dejavu/DejaVuSansMono.ttf'))
args = parser.parse_args()
if json.loads((args.evidence / 'report.json').read_text()).get('success') is not True:
    parser.error('A successful complete example run is required')
args.evidence = args.evidence.resolve()
args.output.mkdir(parents=True, exist_ok=False)
events = json.loads((args.evidence / 'recording.json').read_text())
commands = {e['name']: e for e in events if e['kind'] in ('command', 'server')}
font = ImageFont.truetype(str(args.font), 17)
heading = ImageFont.truetype(str(args.font), 22)
small = ImageFont.truetype(str(args.font), 14)
used = {}


def excerpt(name, keys):
    path = args.evidence / name
    used[name] = hashlib.sha256(path.read_bytes()).hexdigest()
    data = json.loads(path.read_text())
    return json.dumps({k: data[k] for k in keys}, indent=2)


def step(name, title, output=None, command=None):
    event = commands[name]
    result = output if output is not None else event.get('stdout', '') + event.get('stderr', '') + event.get('output', '')
    return title, command or event['command'], result.strip()


def export_excerpt():
    raw = commands['known-export']['stdout'].strip()
    decoder, results = json.JSONDecoder(), []
    while raw:
        data, end = decoder.raw_decode(raw)
        results.append({k: data[k] for k in ('status', 'path', 'format', 'detached') if k in data})
        raw = raw[end:].strip()
    return json.dumps(results, indent=2)


success = [
    step('known-init', '1. Import the reviewed assignment', excerpt('known-review.json', ['ready'])),
    step('known-generate', '2. Generate and verify', excerpt('known-verify.json', ['success', 'failed'])),
    step('known-export', '3. Export Ruby, HTML and Bruno', export_excerpt()),
    step('demo', '4. Start the generated-adapter demo'),
    step('demo-payment', '5. Create through the adapter', excerpt('create.json', ['success', 'status', 'provider_id']),
         commands['demo-payment']['command'].split('\ncurl')[0]),
    step('demo-payment', '6. Observe settlement and one provider payout',
         'poll-2.json (excerpt):\n' + excerpt('poll-2.json', ['status']) + '\nevidence.json (excerpt):\n' + excerpt('evidence.json', ['created_count']),
         '\n'.join(commands['demo-payment']['command'].splitlines()[-2:])),
]
blocked = json.loads(commands['unknown-blocked']['stderr'])
unknown = json.loads((args.evidence / 'unknown-review.json').read_text())
unknown_excerpt = json.dumps({'ready': unknown['ready'], 'create_candidates': [c['operation_id'] for c in unknown['candidates']['create']], 'operator_review_paths': [d['path'] for d in unknown['diagnostics'] if d['code'] == 'OPERATOR_REVIEW_REQUIRED']}, indent=2)
review = [
    step('unknown-init', '1. Similar names do not prove payment meaning', unknown_excerpt),
    step('unknown-blocked', '2. Generation refuses unresolved semantics',
         json.dumps({'error': {'code': blocked['error']['code']}, 'exit_code': commands['unknown-blocked']['exit']}, indent=2)),
    step('partial-review', '3. Partial answers do not approve other fields', excerpt('partial-review.json', ['ready'])),
    step('resolved-review', '4. Explicit contract decisions unlock generation',
         'resolved-review.json (excerpt):\n' + excerpt('resolved-review.json', ['ready']) + '\nresolved-verify.json (excerpt):\n' + excerpt('resolved-verify.json', ['success', 'failed'])),
]


def render(name, steps):
    frames, transcript = [], []
    for index, (title, command, result) in enumerate(steps):
        # Portable display only: replace the random absolute work directory and ports.
        result = result.replace(str(args.evidence), '$PAYGEN_EXAMPLES_DIR')
        lines = []
        for line in ('$ ' + command.strip()).splitlines():
            lines += [(part, '#d6e7ff') for part in textwrap.wrap(line, 102, replace_whitespace=False, drop_whitespace=False) or ['']]
        lines.append(('', '#94a3b8'))
        lines.append(('Captured output / selected JSON fields:', '#94a3b8'))
        for line in result.splitlines():
            lines += [(part, '#86efac') for part in textwrap.wrap(line, 102, replace_whitespace=False, drop_whitespace=False) or ['']]
        # Paginate rather than silently clipping commands or output.
        page_count = (len(lines) + 22) // 23
        page_size = (len(lines) + page_count - 1) // page_count
        pages = [lines[i:i + page_size] for i in range(0, len(lines), page_size)]
        for page_index, page in enumerate(pages):
            frame = Image.new('RGB', (1120, 700), '#0b1220')
            draw = ImageDraw.Draw(frame)
            draw.rounded_rectangle((14, 14, 1106, 686), radius=16, fill='#111c2e', outline='#334155')
            draw.text((36, 31), 'PAYGEN / ' + title, font=heading, fill='#f8fafc')
            draw.text((36, 68), 'Real local run | synthetic payments | excerpts | playback timing shortened', font=small, fill='#94a3b8')
            for row, (line, color) in enumerate(page):
                draw.text((36, 107 + row * 23), line, font=font, fill=color)
            draw.text((36, 659), f'Step {index + 1}/{len(steps)}  ·  Page {page_index + 1}/{len(pages)}  ·  Full commands and assertions in the walkthrough', font=small, fill='#94a3b8')
            frames.append(frame)
        transcript.append(f'## {title}\n\n$ {command}\n\nCaptured output / selected JSON fields:\n{result}\n')
    frames[0].save(args.output / f'{name}.gif', save_all=True, append_images=frames[1:], duration=6500, loop=0, optimize=False)
    frames[0].save(args.output / f'{name}-poster.png')
    (args.output / f'{name}.txt').write_text('\n'.join(transcript))


render('confirmed-contract', success)
render('operator-review', review)
used['unknown-review.json'] = hashlib.sha256((args.evidence / 'unknown-review.json').read_bytes()).hexdigest()
used['recording.json'] = hashlib.sha256((args.evidence / 'recording.json').read_bytes()).hexdigest()
used['report.json'] = hashlib.sha256((args.evidence / 'report.json').read_bytes()).hexdigest()
(args.output / 'capture-manifest.json').write_text(json.dumps({'kind': 'rendered_verified_terminal_recording', 'timing': '6500ms per page; not real elapsed time', 'evidence_sha256': used}, indent=2) + '\n')
print(args.output)
