#!/bin/bash

# Enhanced Laravel Deployment Script with Rollback & Health Monitoring
# Automates deployment with error handling, rollback capability, logging, and health checks

# ==== CONFIGURATION =================================================#
PROJECT_DIR="/local/path/to/laravel"          # Local path to your Laravel project
SSH_KEY="/path/to/your-key.pem"               # SSH private key
SERVER_USER="ubuntu"                          # Remote server SSH user
SERVER_IP="your.server.ip.address"            # Remote server IP or hostname
REMOTE_BASE="/var/www/your-domain.com"        # Remote webroot (project root)
ARCHIVE_NAME="laravel-$(date +%Y%m%d-%H%M%S).tar.gz"  # Timestamped archive
PHP_FPM_SERVICE="php8.1-fpm"                  # PHP-FPM service name
NGINX_SERVICE="nginx"                         # Nginx service name
SUPERVISOR_GROUP="laravel-worker:*"           # Supervisor group for queue workers

# Backup and logging settings
BACKUP_RETENTION=5                            # Number of backups to keep
LOG_DIR="./deployment-logs"                   # Local log directory
REMOTE_LOG_DIR="/var/log/laravel-deploy"      # Remote log directory
LOG_FILE="$LOG_DIR/deploy-$(date +%Y%m%d-%H%M%S).log"
HEALTH_CHECK_URL="http://localhost"           # Health check endpoint
HEALTH_CHECK_PATH="/health"                   # Optional health check path
DB_CONNECTION_TEST="true"                     # Test database connection

# Exclude patterns
EXCLUDES=(--exclude="vendor" --exclude="node_modules" --exclude="storage/*.key" --exclude=".git" --exclude="tests" --exclude="*.log")
# =======================================================================

# Global variables
DEPLOYMENT_ID=$(date +%Y%m%d-%H%M%S)
REMOTE_BACKUP_DIR=""
ROLLBACK_TRIGGERED=false
EXIT_CODE=0

# Colored output helpers
RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'; BLUE='\033[0;34m'; 
PURPLE='\033[0;35m'; CYAN='\033[0;36m'; NC='\033[0m'

function print_status()  { echo -e "${BLUE}[INFO]${NC}    $1" | tee -a "$LOG_FILE"; }
function print_success() { echo -e "${GREEN}[SUCCESS]${NC} $1" | tee -a "$LOG_FILE"; }
function print_warning() { echo -e "${YELLOW}[WARNING]${NC} $1" | tee -a "$LOG_FILE"; }
function print_error()   { echo -e "${RED}[ERROR]${NC}   $1" | tee -a "$LOG_FILE"; }
function print_debug()   { echo -e "${PURPLE}[DEBUG]${NC}   $1" | tee -a "$LOG_FILE"; }
function print_health()  { echo -e "${CYAN}[HEALTH]${NC}  $1" | tee -a "$LOG_FILE"; }

function log_command() {
    local cmd="$1"
    echo "[CMD] $(date '+%Y-%m-%d %H:%M:%S') - Executing: $cmd" >> "$LOG_FILE"
    eval "$cmd" 2>&1 | tee -a "$LOG_FILE"
    return ${PIPESTATUS[0]}
}

function check_prerequisites() {
    print_status "Checking prerequisites..."
    
    # Check if required commands exist
    for cmd in ssh scp tar php composer; do
        if ! command -v $cmd &> /dev/null; then
            print_error "Required command '$cmd' not found"
            return 1
        fi
    done
    
    # Check SSH key
    if [ ! -f "$SSH_KEY" ]; then
        print_error "SSH key not found: $SSH_KEY"
        return 1
    fi
    
    # Check project directory
    if [ ! -d "$PROJECT_DIR" ]; then
        print_error "Project directory not found: $PROJECT_DIR"
        return 1
    fi
    
    # Check Laravel project structure
    if [ ! -f "$PROJECT_DIR/artisan" ]; then
        print_error "Not a valid Laravel project (artisan not found)"
        return 1
    fi
    
    print_success "Prerequisites check passed"
    return 0
}

function test_connectivity() {
    print_status "Testing server connectivity..."
    
    # Test SSH connectivity
    if ! ssh -i "$SSH_KEY" -o ConnectTimeout=10 -o BatchMode=yes $SERVER_USER@$SERVER_IP exit 2>/dev/null; then
        print_error "SSH connection failed to $SERVER_USER@$SERVER_IP"
        print_error "Please check: SSH key permissions, server IP, firewall settings"
        return 1
    fi
    
    print_success "Server connectivity test passed"
    return 0
}

function create_backup() {
    print_status "Creating backup of current deployment..."
    
    REMOTE_BACKUP_DIR="/tmp/laravel-backup-$DEPLOYMENT_ID"
    
    ssh -i "$SSH_KEY" $SERVER_USER@$SERVER_IP bash -s << ENDSSH 2>&1 | tee -a "$LOG_FILE"
        set -e
        
        # Create backup directory
        mkdir -p "$REMOTE_BACKUP_DIR"
        
        # Check if deployment exists
        if [ -d "$REMOTE_BASE" ]; then
            echo "[BACKUP] Backing up current deployment..."
            cp -r "$REMOTE_BASE" "$REMOTE_BACKUP_DIR/current"
            echo "[BACKUP] Current deployment backed up to $REMOTE_BACKUP_DIR"
        else
            echo "[BACKUP] No existing deployment found, creating directory structure"
            sudo mkdir -p "$REMOTE_BASE"
            sudo chown $SERVER_USER:$SERVER_USER "$REMOTE_BASE"
        fi
        
        # Clean old backups (keep only BACKUP_RETENTION)
        find /tmp -name "laravel-backup-*" -type d -mtime +$BACKUP_RETENTION -exec rm -rf {} + 2>/dev/null || true
        
        echo "[BACKUP] Backup creation completed"
ENDSSH
    
    if [ $? -eq 0 ]; then
        print_success "Backup created successfully at $REMOTE_BACKUP_DIR"
        return 0
    else
        print_error "Failed to create backup"
        return 1
    fi
}

function rollback_deployment() {
    if [ "$ROLLBACK_TRIGGERED" = true ]; then
        print_warning "Rollback already in progress, skipping..."
        return 0
    fi
    
    ROLLBACK_TRIGGERED=true
    print_warning "Initiating rollback procedure..."
    
    if [ -z "$REMOTE_BACKUP_DIR" ]; then
        print_error "No backup directory available for rollback"
        return 1
    fi
    
    ssh -i "$SSH_KEY" $SERVER_USER@$SERVER_IP bash -s << ENDSSH 2>&1 | tee -a "$LOG_FILE"
        set -e
        
        echo "[ROLLBACK] Starting rollback process..."
        
        if [ -d "$REMOTE_BACKUP_DIR/current" ]; then
            # Stop services
            sudo systemctl stop $PHP_FPM_SERVICE || true
            sudo systemctl stop $NGINX_SERVICE || true
            
            # Restore from backup
            rm -rf "$REMOTE_BASE" || true
            cp -r "$REMOTE_BACKUP_DIR/current" "$REMOTE_BASE"
            
            # Restore permissions
            sudo chown -R www-data:www-data "$REMOTE_BASE"
            
            # Restart services
            sudo systemctl start $PHP_FPM_SERVICE
            sudo systemctl start $NGINX_SERVICE
            
            echo "[ROLLBACK] Rollback completed successfully"
        else
            echo "[ROLLBACK] No backup found, cannot rollback"
            exit 1
        fi
ENDSSH
    
    if [ $? -eq 0 ]; then
        print_success "Rollback completed successfully"
        return 0
    else
        print_error "Rollback failed"
        return 1
    fi
}

function cleanup_on_error() {
    local exit_code=$1
    print_error "Deployment failed with exit code: $exit_code"
    
    # Attempt rollback
    rollback_deployment
    
    # Cleanup local files
    [ -f "$ARCHIVE_NAME" ] && rm -f "$ARCHIVE_NAME"
    
    # Copy logs to remote if possible
    upload_logs_to_remote
    
    print_error "Deployment terminated. Check logs: $LOG_FILE"
    exit $exit_code
}

function upload_logs_to_remote() {
    print_status "Uploading logs to remote server..."
    
    ssh -i "$SSH_KEY" $SERVER_USER@$SERVER_IP "sudo mkdir -p $REMOTE_LOG_DIR && sudo chown $SERVER_USER:$SERVER_USER $REMOTE_LOG_DIR" 2>/dev/null || true
    scp -i "$SSH_KEY" "$LOG_FILE" $SERVER_USER@$SERVER_IP:$REMOTE_LOG_DIR/ 2>/dev/null || print_warning "Failed to upload logs to remote"
}

function system_health_check() {
    print_health "Performing comprehensive system health check..."
    
    ssh -i "$SSH_KEY" $SERVER_USER@$SERVER_IP bash -s << 'ENDSSH' 2>&1 | tee -a "$LOG_FILE"
        echo "=================================="
        echo "🏥 SYSTEM HEALTH REPORT"
        echo "=================================="
        echo "Timestamp: $(date)"
        echo ""
        
        # System Information
        echo "📊 SYSTEM INFORMATION:"
        echo "OS: $(lsb_release -d 2>/dev/null | cut -f2 || uname -a)"
        echo "Kernel: $(uname -r)"
        echo "Architecture: $(uname -m)"
        echo "Uptime: $(uptime -p 2>/dev/null || uptime)"
        echo ""
        
        # CPU and Memory
        echo "💻 CPU & MEMORY:"
        echo "CPU Usage: $(top -bn1 | grep "Cpu(s)" | awk '{print $2}' | cut -d'%' -f1)%"
        echo "Memory Usage:"
        free -h
        echo ""
        
        # Disk Space
        echo "💾 DISK SPACE:"
        df -h | grep -E '^/dev|^tmpfs' | head -10
        echo ""
        
        # Network
        echo "🌐 NETWORK:"
        echo "Network interfaces:"
        ip addr show | grep -E '^[0-9]+:|inet ' | head -10
        echo ""
        
        # Services Status
        echo "⚙️  CRITICAL SERVICES:"
        for service in $PHP_FPM_SERVICE $NGINX_SERVICE mysql postgresql redis-server; do
            if systemctl is-active --quiet $service 2>/dev/null; then
                echo "✅ $service: RUNNING"
            elif systemctl list-unit-files | grep -q "^$service"; then
                echo "❌ $service: STOPPED/FAILED"
            else
                echo "➖ $service: NOT INSTALLED"
            fi
        done
        echo ""
        
        # PHP Information
        echo "🐘 PHP INFORMATION:"
        php -v | head -1
        echo "PHP-FPM Status: $(systemctl is-active $PHP_FPM_SERVICE 2>/dev/null || echo 'Unknown')"
        echo "PHP Extensions (critical):"
        for ext in pdo mysql mysqli curl gd mbstring xml zip; do
            if php -m | grep -q "^$ext$"; then
                echo "✅ $ext"
            else
                echo "❌ $ext (missing)"
            fi
        done
        echo ""
        
        # Laravel Application
        echo "🚀 LARAVEL APPLICATION:"
        if [ -f "$REMOTE_BASE/artisan" ]; then
            cd "$REMOTE_BASE"
            echo "Laravel Version: $(php artisan --version 2>/dev/null || echo 'Unable to determine')"
            echo "Environment: $(grep '^APP_ENV=' .env 2>/dev/null | cut -d'=' -f2 || echo 'Unknown')"
            echo "Debug Mode: $(grep '^APP_DEBUG=' .env 2>/dev/null | cut -d'=' -f2 || echo 'Unknown')"
            
            # Test database connection
            if [ "$DB_CONNECTION_TEST" = "true" ]; then
                echo "Database Connection:"
                if timeout 10 php artisan migrate:status >/dev/null 2>&1; then
                    echo "✅ Database: CONNECTED"
                else
                    echo "❌ Database: CONNECTION FAILED"
                fi
            fi
            
            # Check critical directories
            for dir in storage bootstrap/cache; do
                if [ -w "$dir" ]; then
                    echo "✅ $dir: WRITABLE"
                else
                    echo "❌ $dir: NOT WRITABLE"
                fi
            done
        else
            echo "❌ Laravel application not found at $REMOTE_BASE"
        fi
        echo ""
        
        # Log Files
        echo "📝 RECENT LOG ACTIVITY:"
        echo "Laravel Logs (last 5 lines):"
        tail -5 "$REMOTE_BASE/storage/logs/laravel.log" 2>/dev/null || echo "No Laravel logs found"
        echo ""
        echo "Nginx Error Logs (last 3 lines):"
        sudo tail -3 /var/log/nginx/error.log 2>/dev/null || echo "No Nginx error logs accessible"
        echo ""
        
        # Process Information
        echo "🔄 RUNNING PROCESSES:"
        echo "Laravel Queue Workers:"
        ps aux | grep -v grep | grep -E 'artisan.*queue|supervisor' || echo "No queue workers found"
        echo ""
        
        echo "=================================="
        echo "✅ Health check completed"
        echo "=================================="
ENDSSH
    
    if [ $? -eq 0 ]; then
        print_success "System health check completed"
        return 0
    else
        print_warning "System health check completed with warnings"
        return 0
    fi
}

function test_application_health() {
    print_status "Testing application health..."
    
    # Test main endpoint
    local test_url="$HEALTH_CHECK_URL$HEALTH_CHECK_PATH"
    
    ssh -i "$SSH_KEY" $SERVER_USER@$SERVER_IP bash -s << ENDSSH 2>&1 | tee -a "$LOG_FILE"
        echo "[HEALTH] Testing application endpoint: $test_url"
        
        # Test with curl
        if curl -fsS --connect-timeout 10 --max-time 30 "$test_url" >/dev/null 2>&1; then
            echo "[HEALTH] ✅ Application endpoint responding"
            
            # Get response time
            response_time=\$(curl -o /dev/null -s -w "%{time_total}" "$test_url" 2>/dev/null || echo "unknown")
            echo "[HEALTH] Response time: \${response_time}s"
            
            # Check HTTP status
            status_code=\$(curl -o /dev/null -s -w "%{http_code}" "$test_url" 2>/dev/null || echo "000")
            echo "[HEALTH] HTTP Status: \$status_code"
            
            if [ "\$status_code" -ge 200 ] && [ "\$status_code" -lt 400 ]; then
                echo "[HEALTH] ✅ Application is healthy"
                exit 0
            else
                echo "[HEALTH] ❌ Application returned error status: \$status_code"
                exit 1
            fi
        else
            echo "[HEALTH] ❌ Application endpoint not responding"
            echo "[HEALTH] Checking if services are running..."
            
            systemctl is-active --quiet $PHP_FPM_SERVICE && echo "[HEALTH] PHP-FPM: Running" || echo "[HEALTH] PHP-FPM: Not running"
            systemctl is-active --quiet $NGINX_SERVICE && echo "[HEALTH] Nginx: Running" || echo "[HEALTH] Nginx: Not running"
            
            exit 1
        fi
ENDSSH
    
    return $?
}

# Trap for cleanup on error
trap 'cleanup_on_error $?' ERR
trap 'cleanup_on_error 130' INT  # Ctrl+C
trap 'cleanup_on_error 143' TERM # Termination

# Setup logging
mkdir -p "$LOG_DIR"
touch "$LOG_FILE"

echo "================================================"
echo "🚀 Enhanced Laravel Deployment v2.0"
echo "================================================"
echo "Deployment ID: $DEPLOYMENT_ID"
echo "Log file: $LOG_FILE"
echo "================================================"

# Pre-deployment checks
check_prerequisites || exit 1
test_connectivity || exit 1

# Create backup before deployment
create_backup || exit 1

# Create and upload archive
print_status "Creating deployment archive..."
log_command "tar -czf '$ARCHIVE_NAME' -C '$(dirname "$PROJECT_DIR")' '$(basename "$PROJECT_DIR")' ${EXCLUDES[*]}"
if [ $? -ne 0 ]; then
    print_error "Failed to create archive"
    exit 1
fi
print_success "Archive created: $ARCHIVE_NAME"

print_status "Uploading archive to server..."
log_command "scp -i '$SSH_KEY' '$ARCHIVE_NAME' $SERVER_USER@$SERVER_IP:$REMOTE_BASE/"
if [ $? -ne 0 ]; then
    print_error "Failed to upload archive"
    exit 1
fi
print_success "Archive uploaded successfully"

# Remote deployment with comprehensive error handling
print_status "Executing remote deployment..."
ssh -i "$SSH_KEY" $SERVER_USER@$SERVER_IP bash -s << 'ENDSSH' 2>&1 | tee -a "$LOG_FILE"
    set -e
    
    # Function for remote error handling
    handle_remote_error() {
        echo "[REMOTE ERROR] $1"
        echo "[REMOTE ERROR] Deployment step failed at: $(date)"
        exit 1
    }
    
    cd "$REMOTE_BASE" || handle_remote_error "Cannot access remote directory"
    
    echo "[REMOTE] Starting deployment process..."
    echo "[REMOTE] Working directory: $(pwd)"
    
    # Extract archive
    echo "[REMOTE] Extracting archive..."
    tar -xzf "$ARCHIVE_NAME" --strip-components=1 || handle_remote_error "Archive extraction failed"
    rm "$ARCHIVE_NAME"
    echo "[REMOTE] ✅ Archive extracted"
    
    # Environment setup
    if [ -f .env.example ] && [ ! -f .env ]; then
        cp .env.example .env
        echo "[REMOTE] ✅ Environment file created from example"
    fi
    
    # Check PHP version compatibility
    php_version=$(php -r "echo PHP_VERSION_ID;")
    if [ "$php_version" -lt 80000 ]; then
        handle_remote_error "PHP version too old (requires 8.0+)"
    fi
    echo "[REMOTE] ✅ PHP version check passed"
    
    # Composer install with error handling
    echo "[REMOTE] Installing Composer dependencies..."
    if ! composer install --no-interaction --prefer-dist --optimize-autoloader --no-dev 2>&1; then
        handle_remote_error "Composer install failed"
    fi
    echo "[REMOTE] ✅ Composer dependencies installed"
    
    # Generate app key if needed
    if ! grep -q 'APP_KEY=base64:' .env 2>/dev/null; then
        php artisan key:generate --force || handle_remote_error "Key generation failed"
        echo "[REMOTE] ✅ Application key generated"
    fi
    
    # Database migrations with backup
    echo "[REMOTE] Running database migrations..."
    if ! php artisan migrate --force 2>&1; then
        handle_remote_error "Database migration failed"
    fi
    echo "[REMOTE] ✅ Database migrations completed"
    
    # Asset building (if applicable)
    if [ -f package.json ]; then
        echo "[REMOTE] Installing Node.js dependencies..."
        if ! npm ci --production 2>&1; then
            handle_remote_error "NPM install failed"
        fi
        
        if [ -f vite.config.js ] || [ -f webpack.mix.js ]; then
            echo "[REMOTE] Building frontend assets..."
            if ! npm run build 2>&1; then
                handle_remote_error "Asset build failed"
            fi
            echo "[REMOTE] ✅ Frontend assets built"
        fi
    fi
    
    # Cache operations
    echo "[REMOTE] Optimizing application caches..."
    php artisan cache:clear || handle_remote_error "Cache clear failed"
    php artisan config:cache || handle_remote_error "Config cache failed"
    php artisan route:cache || handle_remote_error "Route cache failed"
    php artisan view:cache || handle_remote_error "View cache failed"
    echo "[REMOTE] ✅ Application caches optimized"
    
    # Permission setting with verification
    echo "[REMOTE] Setting file permissions..."
    sudo chown -R www-data:www-data "$REMOTE_BASE" || handle_remote_error "Ownership change failed"
    
    # Set specific permissions for storage and cache
    find storage -type d -exec chmod 775 {} \; 2>/dev/null || handle_remote_error "Storage directory permissions failed"
    find storage -type f -exec chmod 664 {} \; 2>/dev/null || handle_remote_error "Storage file permissions failed"
    find bootstrap/cache -type d -exec chmod 775 {} \; 2>/dev/null || handle_remote_error "Cache directory permissions failed"
    echo "[REMOTE] ✅ File permissions set"
    
    # Service management with health checks
    echo "[REMOTE] Restarting services..."
    
    # PHP-FPM
    if ! sudo systemctl restart "$PHP_FPM_SERVICE"; then
        handle_remote_error "PHP-FPM restart failed"
    fi
    
    # Wait and verify PHP-FPM
    sleep 2
    if ! systemctl is-active --quiet "$PHP_FPM_SERVICE"; then
        handle_remote_error "PHP-FPM failed to start properly"
    fi
    
    # Nginx
    if ! sudo systemctl restart "$NGINX_SERVICE"; then
        handle_remote_error "Nginx restart failed"
    fi
    
    # Wait and verify Nginx
    sleep 2
    if ! systemctl is-active --quiet "$NGINX_SERVICE"; then
        handle_remote_error "Nginx failed to start properly"
    fi
    
    echo "[REMOTE] ✅ Services restarted successfully"
    
    # Queue workers (if supervisor is available)
    if command -v supervisorctl > /dev/null 2>&1; then
        echo "[REMOTE] Restarting queue workers..."
        sudo supervisorctl restart "$SUPERVISOR_GROUP" 2>/dev/null || echo "[REMOTE] No queue workers to restart"
    fi
    
    echo "[REMOTE] ✅ Remote deployment completed successfully"
ENDSSH

REMOTE_EXIT_CODE=$?
if [ $REMOTE_EXIT_CODE -ne 0 ]; then
    print_error "Remote deployment failed"
    cleanup_on_error $REMOTE_EXIT_CODE
fi

print_success "Remote deployment completed successfully"

# Application health test
print_status "Testing application health..."
if ! test_application_health; then
    print_error "Application health check failed"
    cleanup_on_error 1
fi

# Comprehensive system health check
system_health_check

# Cleanup
print_status "Cleaning up local files..."
rm -f "$ARCHIVE_NAME"
print_success "Local cleanup completed"

# Upload logs to remote
upload_logs_to_remote

# Final success message
echo ""
echo "🎉================================================"
echo "   DEPLOYMENT COMPLETED SUCCESSFULLY!"
echo "================================================"
echo "Deployment ID: $DEPLOYMENT_ID"
echo "Backup Location: $REMOTE_BACKUP_DIR"
echo "Log File: $LOG_FILE"
echo "================================================"

print_success "Deployment finished successfully at $(date)"
exit 0
