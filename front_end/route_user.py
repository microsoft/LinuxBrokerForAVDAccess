import logging

from flask import render_template, session
from function_authentication import login_required

logger = logging.getLogger(__name__)

def register_route_user(app):
    @app.route('/profile')
    @login_required
    def profile():
        try:
            user = session.get('user')
            return render_template(
                'profile.html',
                user=user
            )
        except Exception as e:
            logger.error(f"Error rendering profile: {e}")
            return render_template('error.html')
