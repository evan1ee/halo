#!/usr/bin/env python3
"""Checks the Synapse behaviour that the read-state scenario model (HaloApplicationTests/ReadStateScenarioTests.swift)
assumes. Needs the dev homeserver (infra/dev) and Docker (users are created with register_new_matrix_user).
Creates two throwaway users per run. Exit status 1 and a diff of expected/actual if the server disagrees.
Usage: tools/server-rules/check_server_rules.py   (HALO_DEV_SERVER overrides http://localhost:8008)"""
import json, os, secrets, urllib.request, urllib.parse, subprocess, sys, time, uuid
B=os.environ.get("HALO_DEV_SERVER","http://localhost:8008")+"/_matrix/client/v3"
PASSWORD=secrets.token_hex(12)  # throwaway accounts on the local dev server only
def req(method, path, token=None, body=None):
    r=urllib.request.Request(B+path, method=method, data=json.dumps(body).encode() if body is not None else None, headers={"content-type":"application/json", **({"Authorization":"Bearer "+token} if token else {})})
    try:
        with urllib.request.urlopen(r, timeout=20) as f: return json.load(f)
    except urllib.error.HTTPError as e: return {"_err":e.code, **json.load(e)}
def register(name, pw):
    subprocess.run(["docker","exec","-i","halo-dev-synapse-1","register_new_matrix_user","-c","/data/homeserver.yaml","-u",name,"--password-file","/dev/stdin","--no-admin","--exists-ok","http://localhost:8008"],input=pw.encode(),capture_output=True)
    d=req("POST","/login",None,{"type":"m.login.password","identifier":{"type":"m.id.user","user":name},"password":pw}); return d["access_token"], d["user_id"]
q=urllib.parse.quote
class U:
    def __init__(s,name):
        s.name=name; s.tok,s.id=register(name,PASSWORD)
    def send(s,room,body,extra=None,typ="m.room.message"):
        c={"msgtype":"m.text","body":body}; c.update(extra or {})
        return req("PUT",f"/rooms/{q(room)}/send/{typ}/{uuid.uuid4().hex}",s.tok,c)["event_id"]
    def counts(s,room):
        time.sleep(0.4); d=req("GET",f"/sync?timeout={__import__('random').randint(1,9999)}",s.tok)
        r=d.get("rooms",{}).get("join",{}).get(room,{}); n=r.get("unread_notifications",{}); return n.get("notification_count",0), n.get("highlight_count",0)
    def read(s,room,ev): req("POST",f"/rooms/{q(room)}/receipt/m.read/{q(ev)}",s.tok,{})
import random
sfx=uuid.uuid4().hex[:5]
a=U("rules_a"+sfx); b=U("rules_b"+sfx)
def mkroom(enc=False):
    r=req("POST","/createRoom",a.tok,{"preset":"private_chat","invite":[b.id]})["room_id"]
    req("POST",f"/join/{q(r)}",b.tok,{})
    if enc: req("PUT",f"/rooms/{q(r)}/state/m.room.encryption",a.tok,{"algorithm":"m.megolm.v1.aes-sha2"})
    return r
ENC={"algorithm":"m.megolm.v1.aes-sha2","ciphertext":"x","sender_key":"k","session_id":"s","device_id":"d"}
mention=lambda: {"m.mentions":{"user_ids":[a.id]}}
results=[]
def check(name, got, want): results.append((name, got, want))

r=mkroom(); e=[b.send(r,f"m{i}") for i in range(3)]
check("3 plain messages from B notify", a.counts(r), (3,0))
b.send(r,"hi",mention()); check("an m.mentions mention adds a notification and a highlight", a.counts(r), (4,1))
b.send(r,"* edited",{"m.new_content":{"msgtype":"m.text","body":"edited"},"m.relates_to":{"rel_type":"m.replace","event_id":e[0]}})
check("an edit does not count", a.counts(r), (4,1))
req("PUT",f"/rooms/{q(r)}/redact/{e[1]}/{uuid.uuid4().hex}",b.tok,{}); check("redacting an unread message removes it from the count", a.counts(r), (3,1))
b.send(r,"in thread",{"m.relates_to":{"rel_type":"m.thread","event_id":e[2]}}); check("a thread reply counts", a.counts(r), (4,1))
a.send(r,"mine"); check("the user's own message does NOT reset the counts", a.counts(r), (4,1))
last=b.send(r,"y"); a.read(r,last); check("a read receipt at the latest event zeroes the counts", a.counts(r), (0,0))
req("PUT",f"/user/{q(a.id)}/rooms/{q(r)}/account_data/m.marked_unread",a.tok,{"unread":True}); check("m.marked_unread does not change the counts", a.counts(r), (0,0))

r2=mkroom(); req("PUT",f"/pushrules/global/room/{q(r2)}",a.tok,{"actions":[]})
b.send(r2,"quiet"); check("room rule with no actions (mentions-only): a plain message does not count", a.counts(r2), (0,0))
b.send(r2,"hi",mention()); check("room rule with no actions: a mention still notifies and highlights", a.counts(r2), (1,1))

r3=mkroom(); req("PUT",f"/pushrules/global/override/{q(r3)}",a.tok,{"conditions":[{"kind":"event_match","key":"room_id","pattern":r3}],"actions":[]})
b.send(r3,"muted"); b.send(r3,"hi",mention()); check("override rule with no actions (mute): nothing counts, mentions included", a.counts(r3), (0,0))

r4=mkroom(True)
for _ in range(2): b.send(r4,"",ENC,typ="m.room.encrypted")
check("encrypted room, all messages: events notify but never highlight", a.counts(r4), (2,0))
req("PUT",f"/pushrules/global/room/{q(r4)}",a.tok,{"actions":[]}); b.send(r4,"",ENC,typ="m.room.encrypted")
check("encrypted room after a no-action room rule: new events are not counted, earlier counts stay", a.counts(r4), (2,0))

bad=[x for x in results if x[1]!=x[2]]
for name,got,want in results: print(("ok   " if got==want else "FAIL ")+f"{name}: got {got}, expected {want}")
sys.exit(1 if bad else 0)
