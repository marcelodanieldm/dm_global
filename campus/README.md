# Campus DM Global (Moodle)

Archivos de configuración inicial de campus.dmglobal.tech (Moodle 5.2 en Docker, VPS Hostinger).

- `setup/setup.php`: idioma, zona horaria, portada, branding (logo, colores, SCSS) y catálogo inicial de categorías y cursos. Es idempotente: no duplica cursos que ya existen.
- `setup/catalog.json`: categorías y cursos (nombre corto, nombre, resumen y secciones).
- `setup/pre.scss` y `setup/post.scss`: estilos del tema Boost alineados con la landing "Mosaico humano".

Se ejecuta desde un contenedor auxiliar (`dmglobal-moodle-ops`) que usa la misma imagen y el mismo volumen que Moodle.
No contiene contraseñas: las credenciales viven en las variables de entorno del proyecto Docker.
