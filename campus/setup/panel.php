<?php
define('CLI_SCRIPT', true);
require('/var/www/html/config.php');
set_config('auth_instructions', file_get_contents('/tmp/panel.html'));
set_config('scss', file_get_contents('/tmp/post.scss'), 'theme_boost');
theme_reset_all_caches();
purge_all_caches();
echo "PANEL OK\n";
