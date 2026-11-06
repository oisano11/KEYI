#!/usr/bin/env python3
"""把评测句交给正在运行的 KEYI 翻译服务，打印译文，供人工对比改动前后的本地模型质量。

用法：python3 -I Tests/KEYILocalModelEval/run.py [providerID]（默认 localModel）
句子全是自造的，不含用户真实内容；选 deepSeek 等云端提供方时会把这些句子发到云端。
"""
import json
import pathlib
import socket
import sys
import uuid

SUPPORT = pathlib.Path.home() / "Library/Application Support/com.keyi.input-translator"
provider = sys.argv[1] if len(sys.argv) > 1 else "localModel"
sentences = json.loads((pathlib.Path(__file__).parent / "sentences.json").read_text())


def translate(text, scene):
    request = {"version": 1, "type": "translate", "id": str(uuid.uuid4()), "text": text,
               "providerID": provider, "targetLanguage": "en", "scene": scene, "timeoutSeconds": 60}
    with socket.socket(socket.AF_UNIX) as connection:
        connection.settimeout(90)
        connection.connect(str(SUPPORT / "translation-service.sock"))
        connection.sendall((json.dumps(request, ensure_ascii=False) + "\n").encode())
        buffer = b""
        while b"\n" not in buffer:
            chunk = connection.recv(65536)
            if not chunk:
                break
            buffer += chunk
    reply = json.loads(buffer.split(b"\n")[0])
    return reply.get("text") or f"[{reply.get('code')}] {reply.get('message')}"


for group, rows in sentences.items():
    for row in rows:
        print(f"{group}\t{row['scene']}\t{row['zh']}\t{translate(row['zh'], row['scene'])}")
