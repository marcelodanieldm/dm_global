<?php
define('CLI_SCRIPT', true);
require('/var/www/html/config.php');
set_config('auth_instructions', file_get_contents('/tmp/panel.html'));
set_config('additionalhtmlhead', '<link rel="preconnect" href="https://fonts.googleapis.com"><link rel="preconnect" href="https://fonts.gstatic.com" crossorigin><link rel="stylesheet" href="https://fonts.googleapis.com/css2?family=Bricolage+Grotesque:opsz,wght@12..96,600;12..96,800&family=DM+Sans:wght@400;500;700&display=swap">');
set_config('scss', file_get_contents('/tmp/post.scss'), 'theme_boost');
theme_reset_all_caches();
purge_all_caches();
$t = theme_config::load('boost'); $m = new ReflectionMethod($t, 'get_css_content_from_scss'); $m->setAccessible(true); $r = $m->invoke($t, false);
echo 'compile: '.($r === false ? 'FALSE' : strlen($r).' dmg='.substr_count($r, 'dmg-tile').' cobalt='.substr_count(strtolower($r), '2d4bf0'))."\n";
echo "PANEL OK\n";
