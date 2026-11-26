# Landing DM Global (Mosaico humano)

- `index.html`: la página lista para subir al servidor. El CSS de Tailwind ya está compilado adentro, así que no depende de ningún CDN.
- Idiomas ES / EN / PT: los textos están en el objeto `I18N`, dentro del `<script>` del final de `index.html`.
- Chatbot y formulario: completa `CONFIG.CHAT_WEBHOOK` y `CONFIG.FORM_WEBHOOK` con las URLs de los webhooks de n8n. Si quedan vacías, el chat da respuestas de demostración y el formulario solo muestra la confirmación.
- Los marcadores `[X]` de la barra de credibilidad se reemplazan por cifras reales.

## Recompilar el CSS si cambias clases de Tailwind
1. Edita `index.src.html`.
2. `npx tailwindcss@3.4.17 -c tailwind.config.js -i input.css -o out.css --minify` (ajusta `content` en `tailwind.config.js` a la ruta de `index.src.html`).
3. Reemplaza `<!--TAILWIND-->` en `index.src.html` por `<style>` + el contenido de `out.css` + `</style>` y guárdalo como `index.html`.

## Responsive y accesibilidad (revisado el 26/11/2026)
- Probado a 320, 375, 768, 1024, 1440 y 1920 px de ancho, sin scroll horizontal.
- axe-core 4.10 (WCAG 2.0/2.1/2.2 A y AA), en ES, EN y PT, con el chat abierto y el error del formulario visible: 0 errores.
- Incluye enlace "Saltar al contenido", foco visible, etiquetas en todos los campos, atributo lang que cambia con el idioma, cierre del chat con Esc y soporte de movimiento reducido.
- Antes de publicar, conviene una prueba manual con lector de pantalla (VoiceOver o NVDA).
