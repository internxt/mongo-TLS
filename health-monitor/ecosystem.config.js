module.exports = {
  apps: [{
    name: 'mongodb-health-check',
    script: 'dist/app.js',
    autorestart: true,
    watch: false,
    restart_delay: 4000,
    env_file: '.env',
    error_file: './logs/err.log',
    out_file: './logs/out.log',
    log_file: './logs/combined.log',
    time: true,
    log_date_format: 'YYYY-MM-DD HH:mm:ss Z'
  }]
};