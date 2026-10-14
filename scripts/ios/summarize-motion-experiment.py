"""Build an offline comparison gallery and sanitized performance summary."""
import argparse
import html
import json
import re
from pathlib import Path


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("experiments", type=Path)
    args = parser.parse_args()
    root = args.experiments
    manifest = json.loads((root / "model-manifest.json").read_text())
    models = [{"id": "camera", "precision": "camera fallback", "packageBytes": 0}] + [
        model for model in manifest["models"] if model["id"] in {"dav2-f16", "dav2-p8", "dav2-p6"}
    ]
    stages = [p.name for p in sorted(root.iterdir()) if p.is_dir() and (p / "results.json").exists()]
    stages = [stage for stage in stages if stage == "dav2-product-mac"]
    records = {}
    for stage in stages:
        file = root / stage / "performance.log"
        rows = []
        if file.exists():
            for line in file.read_text().splitlines():
                if not line.startswith("phase="):
                    continue
                fields = dict(re.findall(r"([A-Za-z]+)=([^\s]+)", line))
                rows.append(fields)
            (root / stage / "performance.json").write_text(json.dumps(rows, indent=2) + "\n")
        records[stage] = rows
    options = "".join(f'<option value="{html.escape(stage)}">{html.escape(stage)}</option>' for stage in stages)
    page = '''<!doctype html><html lang="zh-CN"><meta charset="utf-8"><meta name="viewport" content="width=device-width, initial-scale=1">
<title>动态封面 · 本地实验对比</title><style>
*{box-sizing:border-box}body{margin:0;background:#0b1220;color:#e6edf8;font:15px/1.6 system-ui,sans-serif}main{max-width:1600px;margin:auto;padding:24px}h1{font-size:26px;margin:0 0 8px}p{color:#aab8cc;max-width:1000px}nav{display:flex;gap:12px;flex-wrap:wrap;margin:20px 0;align-items:center}button,select{font:inherit;padding:8px 12px;border:1px solid #41506a;border-radius:8px;background:#202c41;color:inherit;cursor:pointer}label{display:flex;gap:8px;align-items:center}.grid{display:grid;grid-template-columns:repeat(auto-fit,minmax(250px,1fr));gap:18px}article{background:#172238;border:1px solid #2d3d59;border-radius:12px;overflow:hidden}h2{font-size:17px;margin:14px 16px 4px}.meta{font-size:12px;line-height:1.5;color:#b4c3d9;padding:0 16px 12px}.visual{width:100%;display:block;background:#060b14;object-fit:contain;max-height:540px}article a{color:#81c8ff}.links{padding:10px 16px;font-size:12px}.note{font-size:13px}table{border-collapse:collapse;margin:16px 0;width:100%;font-size:12px}td,th{border-bottom:1px solid #34415a;padding:8px;text-align:left}.table{overflow:auto}footer{margin-top:24px;color:#9dacbf;font-size:13px}
</style><main><h1>动态封面 · 本地实验对比</h1><p>同一张封面、相同六秒循环。最新 Mac 实验直接按标量深度做 Metal 逆向采样，并保护识别出的文字。白色表示更近；灰度图反映相对布局，不是统一米制刻度。旧 iPad 版本只影响梯度，可用于对照为何先前只有整体运动。</p>
<nav><label>实验<select id="stage">STAGES</select></label><label>比例<select id="size"><option value="720">1:1</option><option value="960">3:4</option></select></label><label>查看<select id="view"><option value="video">循环视频</option><option value="depth">归一化深度图</option><option value="field">渲染位移场</option><option value="frame">第 36 帧</option></select></label><button id="play">同步播放</button><button id="pause">暂停</button><button id="reset">回到起点</button><label>速度<select id="speed"><option value="1">1×</option><option value="0.5">0.5×</option></select></label></nav>
<div id="grid" class="grid"></div><div id="metrics" class="table"></div><footer>Mac 数字不能代替 iPad 测试。内存为单个原生进程 footprint，每 10ms 采样；基线随模型和 OS 缓存变化，阶段增量不能相加。模型文件未放入本目录。原始数据、完整日志和关键帧保留在各实验目录，详见 <a href="README.md">README</a> / <a href="model-manifest.json">模型来源与校验和</a>。</footer></main>
<script>const models=MODELS;const records=RECORDS;
const stage=document.querySelector('#stage'),size=document.querySelector('#size'),view=document.querySelector('#view'),speed=document.querySelector('#speed');stage.value='dav2-product-mac';
function render(){const old=stage.value.startsWith('ipad-'),base=stage.value;document.querySelector('#grid').replaceChildren();for(const model of models){const card=document.createElement('article'),path=`${base}/${model.id}`;card.innerHTML=`<h2>${model.id}</h2><div class="meta">${model.precision} · ${(model.packageBytes/1e6).toFixed(2)} MB</div>`;let element;if(view.value==='video'){element=document.createElement('video');element.src=old?`${base}/${model.id}.mp4`:`${path}/motion-${size.value}.mp4`;element.muted=true;element.loop=true;element.playsInline=true;element.controls=true;element.preload='metadata';element.playbackRate=Number(speed.value);}else{element=document.createElement('img');element.alt=`${model.id} ${view.value}`;element.src=view.value==='depth'?(old?`${base}/depth-${model.id}.png`:`${path}/depth-normalized.png`):view.value==='field'?`${path}/field-${size.value}.png`:`${path}/frame-${size.value}-36.png`;element.onerror=()=>{element.alt='该基线没有此中间图，或此候选使用整体运动';element.removeAttribute('src');};}element.className='visual';card.append(element);const links=document.createElement('div');links.className='links';links.innerHTML=old?`<a href="${base}/summary.md">iPad 性能记录</a>`:`<a href="${base}/raw-${model.id}.json">原始深度说明</a> · <a href="${base}/raw-${model.id}.f32">原始浮点值</a> · <a href="${base}/performance.log">性能日志</a>`;card.append(links);document.querySelector('#grid').append(card);}const rows=records[base]??[];document.querySelector('#metrics').innerHTML='<table><tr><th>阶段</th><th>候选</th><th>耗时 ms</th><th>基线 MiB</th><th>峰值 MiB</th><th>额外 MiB</th></tr>'+rows.map(r=>`<tr><td>${r.phase}</td><td>${r.backend??'Vision'}</td><td>${r.elapsedMs}</td><td>${r.baselineMiB}</td><td>${r.peakMiB}</td><td>${r.deltaMiB}</td></tr>`).join('')+'</table>';}for(const input of [stage,size,view])input.onchange=render;
const videos=()=>[...document.querySelectorAll('video')];document.querySelector('#play').onclick=()=>{const all=videos();for(const v of all){v.currentTime=0;v.play().catch(()=>{});}};document.querySelector('#pause').onclick=()=>videos().forEach(v=>v.pause());document.querySelector('#reset').onclick=()=>videos().forEach(v=>{v.pause();v.currentTime=0;});speed.onchange=()=>videos().forEach(v=>v.playbackRate=Number(speed.value));render();</script></html>'''
    page = page.replace("STAGES", options).replace("MODELS", json.dumps(models)).replace("RECORDS", json.dumps(records))
    (root / "index.html").write_text(page)
    print(root / "index.html")


if __name__ == "__main__":
    main()
