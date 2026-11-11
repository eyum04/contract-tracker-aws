#!/bin/bash
# Contract Tracker: full app user data for Amazon Linux 2023
#

set -euo pipefail
exec > >(tee /var/log/user-data.log) 2>&1

dnf install -y python3-pip
pip3 install flask gunicorn boto3 psycopg2-binary

mkdir -p /opt/contracts

cat > /opt/contracts/app.py <<'PYEOF'
import json
import os
import uuid

import boto3
import psycopg2
from flask import Flask, redirect, render_template_string, request
from werkzeug.utils import secure_filename

REGION = os.environ.get("AWS_REGION", "us-west-2")
BUCKET = os.environ["BUCKET_NAME"]
SECRET_ID = os.environ["DB_SECRET_ID"]
DB_HOST = os.environ["DB_HOST"]
DB_NAME = os.environ.get("DB_NAME", "contracts")

s3 = boto3.client("s3", region_name=REGION)
secrets = boto3.client("secretsmanager", region_name=REGION)
app = Flask(__name__)

PAGE = """
<h1>Contract Tracker</h1>
<form method="post" action="/contracts" enctype="multipart/form-data">
  <input name="name" placeholder="Contract name" required>
  <input type="date" name="expires" required>
  <input type="file" name="file">
  <button>Add</button>
</form>
<br>
<table border="1" cellpadding="6">
  <tr><th>Name</th><th>Expires</th><th>Days left</th><th>File (S3 key)</th></tr>
  {% for r in rows %}
  <tr><td>{{ r[0] }}</td><td>{{ r[1] }}</td><td>{{ r[2] }}</td><td>{{ r[3] or '' }}</td></tr>
  {% endfor %}
</table>
"""


def get_conn():
    # The database password is never stored on the server. We fetch it from
    # Secrets Manager at request time using the instance's IAM role.
    secret = json.loads(secrets.get_secret_value(SecretId=SECRET_ID)["SecretString"])
    conn = psycopg2.connect(
        host=DB_HOST,
        dbname=DB_NAME,
        user=secret["username"],
        password=secret["password"],
        sslmode="require",
        connect_timeout=5,
    )
    with conn, conn.cursor() as cur:
        cur.execute(
            """CREATE TABLE IF NOT EXISTS contracts (
                   id SERIAL PRIMARY KEY,
                   name TEXT NOT NULL,
                   expires DATE NOT NULL,
                   s3_key TEXT)"""
        )
    return conn


@app.route("/health")
def health():
    # Deliberately does NOT touch the database. See the guide for why.
    return "ok", 200


@app.route("/")
def index():
    conn = get_conn()
    with conn, conn.cursor() as cur:
        cur.execute(
            "SELECT name, expires, (expires - CURRENT_DATE) AS days_left, s3_key "
            "FROM contracts ORDER BY expires"
        )
        rows = cur.fetchall()
    conn.close()
    return render_template_string(PAGE, rows=rows)


@app.route("/contracts", methods=["POST"])
def add_contract():
    name = request.form["name"]
    expires = request.form["expires"]
    key = None
    f = request.files.get("file")
    if f and f.filename:
        key = f"contracts/{uuid.uuid4()}-{secure_filename(f.filename)}"
        s3.upload_fileobj(f, BUCKET, key)
    conn = get_conn()
    with conn, conn.cursor() as cur:
        cur.execute(
            "INSERT INTO contracts (name, expires, s3_key) VALUES (%s, %s, %s)",
            (name, expires, key),
        )
    conn.close()
    return redirect("/")
PYEOF

cat > /etc/contracts.env <<'ENVEOF'
AWS_REGION=us-west-2
BUCKET_NAME=${bucket_name}
DB_SECRET_ID=${secret_arn}
DB_HOST=${db_endpoint}
DB_NAME=contracts
ENVEOF

cat > /etc/systemd/system/contracts.service <<'SVCEOF'
[Unit]
Description=Contract Tracker web app
After=network.target

[Service]
EnvironmentFile=/etc/contracts.env
WorkingDirectory=/opt/contracts
ExecStart=/usr/local/bin/gunicorn -b 0.0.0.0:8080 -w 2 app:app
Restart=always

[Install]
WantedBy=multi-user.target
SVCEOF

systemctl daemon-reload
systemctl enable --now contracts