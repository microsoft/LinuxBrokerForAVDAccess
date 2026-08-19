import os
import logging

from azure.monitor.opentelemetry import configure_azure_monitor

connection_string = os.environ.get('APPLICATIONINSIGHTS_CONNECTION_STRING')
if connection_string:
    configure_azure_monitor(connection_string=connection_string, logger_name='linuxbroker.frontend')

from flask import Flask, jsonify, render_template, send_from_directory
from flask_session import Session
from route_authentication import register_route_authentication
from route_user import register_route_user
from route_vm_management import register_route_vm_management
from route_scaling_management import register_route_scaling_management

# ===============================
# Flask App

app = Flask(__name__)
app.config['SECRET_KEY'] = os.environ.get('FLASK_KEY') 
app.config['SESSION_TYPE'] = 'filesystem'
app.config['VERSION'] = '0.111'
Session(app)

# ===============================
# Logging Configuration

logging.basicConfig(level=logging.INFO)
logger = logging.getLogger('linuxbroker.frontend')

# ===============================
# General Routes

@app.route('/')
def index():
    return render_template('index.html')

@app.route('/health')
def health():
    return jsonify({"status": "healthy", "version": app.config['VERSION']}), 200

@app.route('/favicon.ico')
def favicon():
    return send_from_directory(os.path.join(app.root_path, 'static'), 'favicon.ico', mimetype='image/vnd.microsoft.icon')

# ===============================
# Authentication

register_route_authentication(app)

# ===============================
# User

register_route_user(app)

# ===============================
# VM Management

register_route_vm_management(app)

# ===============================
# Scaling and Scaling Rules

register_route_scaling_management(app)

# ===============================
# Main

if __name__ == '__main__':
    app.run(debug=True)
