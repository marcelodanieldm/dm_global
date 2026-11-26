<?php
define('CLI_SCRIPT', true);
require('/var/www/html/config.php');
require_once($CFG->libdir.'/clilib.php');
require_once($CFG->dirroot.'/course/lib.php');
global $DB, $CFG;
\core\session\manager::set_user(get_admin());
function out($s){ echo $s."\n"; }

// 1. Idiomas
try {
  $c = new \tool_langimport\controller();
  $c->install_languagepacks(['es','pt_br']);
  out('langpacks: '.implode(' | ', $c->info).' ERR:'.implode(' | ', $c->errors));
} catch (\Throwable $e) { out('langpack error: '.$e->getMessage()); }
get_string_manager()->reset_caches();
$langs = array_keys(get_string_manager()->get_list_of_translations(true));
out('langs now: '.implode(',', $langs));
if (in_array('es', $langs)) { set_config('lang', 'es'); $DB->set_field('user', 'lang', 'es', ['id'=>2]); }
set_config('langmenu', 1);
set_config('timezone', 'America/Argentina/Buenos_Aires');
set_config('forcetimezone', 99);
set_config('country', 'AR');
set_config('forcelogin', 0);          // catálogo visible sin login
set_config('guestloginbutton', 0);
set_config('autologinguests', 0);
set_config('frontpage', '4');         // combo categorías+cursos
set_config('frontpageloggedin', '5,4');
set_config('coursesperpage', 20);
set_config('enablecompletion', 1);
set_config('supportemail', 'admin@dmglobal.tech');
set_config('supportname', 'Equipo DM Global');

// 2. Portada
$site = get_site();
$site->fullname = 'DM Global Campus';
$site->shortname = 'DM Global';
$site->summary = '<p><strong>Proyectos de Humanos + Tecnología.</strong> Formación práctica en Transformación Digital, Desarrollo &amp; Calidad y Recursos Humanos. La tecnología es el motor, las personas son el centro.</p><p><a href="https://dmglobal.tech">Volver a dmglobal.tech</a></p>';
$site->summaryformat = FORMAT_HTML;
$DB->update_record('course', $site);

// 3. Branding
$fs = get_file_storage();
$sys = context_system::instance();
foreach (['logo'=>'logo.png','logocompact'=>'logocompact.png','favicon'=>'favicon.png'] as $area=>$fn) {
  $fs->delete_area_files($sys->id, 'core_admin', $area, 0);
  $fs->create_file_from_pathname(['contextid'=>$sys->id,'component'=>'core_admin','filearea'=>$area,'itemid'=>0,'filepath'=>'/','filename'=>$fn], '/tmp/'.$fn);
  set_config($area, '/'.$fn, 'core_admin');
}
set_config('brandcolor', '#2d4bf0', 'theme_boost');
set_config('scsspre', file_get_contents('/tmp/pre.scss'), 'theme_boost');
set_config('scss', file_get_contents('/tmp/post.scss'), 'theme_boost');
set_config('theme', 'boost');

// 4. Categorías y cursos
$data = json_decode(file_get_contents('/tmp/catalog.json'), true);
foreach ($data as $cat) {
  if ($cat['idnumber'] === 'GEN') {
    $rec = $DB->get_record('course_categories', ['id'=>1]);
    $catobj = core_course_category::get(1);
    $catobj->update(['name'=>$cat['name'], 'idnumber'=>'GEN', 'description'=>$cat['desc'], 'descriptionformat'=>FORMAT_HTML]);
  } else if ($id = $DB->get_field('course_categories', 'id', ['idnumber'=>$cat['idnumber']])) {
    $catobj = core_course_category::get($id);
  } else {
    $catobj = core_course_category::create(['name'=>$cat['name'], 'idnumber'=>$cat['idnumber'], 'description'=>$cat['desc'], 'descriptionformat'=>FORMAT_HTML, 'parent'=>0]);
  }
  out("cat {$catobj->id} {$cat['name']}");
  foreach ($cat['courses'] as $c) {
    if ($DB->record_exists('course', ['shortname'=>$c['short']])) { out("  skip {$c['short']}"); continue; }
    $cd = (object)['category'=>$catobj->id, 'fullname'=>$c['full'], 'shortname'=>$c['short'], 'idnumber'=>$c['short'],
      'summary'=>'<p>'.$c['summary'].'</p>', 'summaryformat'=>FORMAT_HTML, 'format'=>'topics',
      'numsections'=>count($c['sections']), 'visible'=>1, 'enablecompletion'=>1, 'lang'=>'', 'startdate'=>make_timestamp(2027,1,4)];
    $course = create_course($cd);
    $i = 0;
    $DB->set_field('course_sections', 'summary', '<p>Bienvenida, presentación del curso y novedades.</p>', ['course'=>$course->id, 'section'=>0]);
    foreach ($c['sections'] as $s) { $i++;
      $DB->set_field('course_sections', 'name', $s, ['course'=>$course->id, 'section'=>$i]);
    }
    rebuild_course_cache($course->id, true);
    out("  course {$course->id} {$c['short']} {$c['full']}");
  }
}
theme_reset_all_caches();
purge_all_caches();
out('SETUP OK');
