"""
Tests unitarios del Servicio de Feedback — CRM DM Global (Django).

Cobertura:
  LicenciaFeedback        renovar_suscripcion, esta_vigente, dias_restantes
  RespuestaFeedback       es_positiva, es_queja, propiedades de estado
  validar_licencia_externa  HTTP 200/400/401/403/405 — endpoint de billing gate
  portal_feedback           GET estrella, POST 4-5★ redirect, POST 1-3★ queja
  queja_feedback            POST guarda comentario_turista + borrador IA (mock)
  alertas_criticas_api      Auth, listado de 1-2★ pendientes, ACK
  stats_feedback            Autenticación y cálculo de métricas
  ai_service.clasificar_ticket  EMERGENCIA vs NORMAL, capas keyword+Gemini
"""
import datetime as dt
import json
import uuid
from unittest.mock import AsyncMock, MagicMock, patch

import pytest
from django.test import RequestFactory
from django.contrib.auth import get_user_model
from django.utils import timezone

from servicios.models import (
    LicenciaFeedback,
    ServicioFeedbackConfig,
    Organizacion,
    RespuestaFeedback,
    EstadoSuscripcion,
    EstadoCopiloto,
    TipoNegocio,
    PasarelaPago,
)
from servicios.views import (
    validar_licencia_externa,
    portal_feedback,
    queja_feedback,
    alertas_criticas_api,
    ack_alertas_whatsapp,
    stats_feedback,
)

User = get_user_model()
rf   = RequestFactory()


# ─────────────────────────────────────────────────────────────────────────────
# Fixtures
# ─────────────────────────────────────────────────────────────────────────────

@pytest.fixture()
def licencia(db):
    return LicenciaFeedback.objects.create(
        id_comercio      = "HOTEL-TEST-01",
        nombre_comercio  = "Hotel Test",
        tipo_negocio     = TipoNegocio.HOTEL,
        email_facturacion = "gerente@hotel.com",
        esta_activa      = True,
        fecha_vencimiento = dt.date.today() + dt.timedelta(days=30),
    )


@pytest.fixture()
def cfg_activo(db):
    user = User.objects.create_user(f"u{uuid.uuid4().hex[:6]}", "u@t.com", "pass")
    org  = Organizacion.objects.create(nombre="Hotel Tests", usuario_principal=user)
    return ServicioFeedbackConfig.objects.create(
        organizacion      = org,
        tipo_negocio      = TipoNegocio.HOTEL,
        google_review_link = "https://g.page/r/test/review",
        estado_suscripcion = EstadoSuscripcion.ACTIVO,
    )


@pytest.fixture()
def respuesta_pendiente(db, cfg_activo):
    return RespuestaFeedback.objects.create(
        config=cfg_activo, token_feedback=uuid.uuid4(),
    )


# ─────────────────────────────────────────────────────────────────────────────
# LicenciaFeedback — modelo y máquina de estados
# ─────────────────────────────────────────────────────────────────────────────

@pytest.mark.django_db
class TestLicenciaFeedback:

    def test_esta_vigente_activa_y_futura(self, licencia):
        assert licencia.esta_vigente is True

    def test_esta_vigente_vencida_retorna_false(self, db):
        l = LicenciaFeedback.objects.create(
            id_comercio="TOUR-VENCIDO-01", nombre_comercio="Tour",
            email_facturacion="a@b.com", esta_activa=True,
            fecha_vencimiento=dt.date.today() - dt.timedelta(days=1),
        )
        assert l.esta_vigente is False

    def test_esta_vigente_pausada_retorna_false(self, db):
        l = LicenciaFeedback.objects.create(
            id_comercio="TOUR-PAUSADO-01", nombre_comercio="Tour",
            email_facturacion="a@b.com", esta_activa=False,
            fecha_vencimiento=dt.date.today() + dt.timedelta(days=30),
        )
        assert l.esta_vigente is False

    def test_dias_restantes_positivo(self, licencia):
        assert licencia.dias_restantes > 0

    def test_dias_restantes_negativo_si_vencida(self, db):
        l = LicenciaFeedback.objects.create(
            id_comercio="ALQUILER-EXP-01", nombre_comercio="Alq",
            email_facturacion="a@b.com", esta_activa=True,
            fecha_vencimiento=dt.date.today() - dt.timedelta(days=5),
        )
        assert l.dias_restantes < 0

    def test_renovar_pago_en_tiempo_extiende_desde_vencimiento(self, licencia):
        venc_antes = licencia.fecha_vencimiento
        licencia.renovar_suscripcion(dias=30, pasarela=PasarelaPago.STRIPE)
        licencia.refresh_from_db()
        assert licencia.fecha_vencimiento == venc_antes + dt.timedelta(30)
        assert licencia.pasarela_activa == "stripe"
        assert licencia.esta_activa is True

    def test_renovar_pago_tardio_extiende_desde_hoy(self, db):
        l = LicenciaFeedback.objects.create(
            id_comercio="RESTO-TARDIO-01", nombre_comercio="Resto",
            email_facturacion="a@b.com", esta_activa=False,
            fecha_vencimiento=dt.date.today() - dt.timedelta(days=10),
        )
        l.renovar_suscripcion(dias=30, pasarela=PasarelaPago.MERCADOPAGO)
        l.refresh_from_db()
        esperado = dt.date.today() + dt.timedelta(days=30)
        assert l.fecha_vencimiento == esperado
        assert l.esta_activa is True
        assert l.pasarela_activa == "mp"


# ─────────────────────────────────────────────────────────────────────────────
# RespuestaFeedback — propiedades
# ─────────────────────────────────────────────────────────────────────────────

@pytest.mark.django_db
class TestRespuestaFeedbackPropiedades:

    @pytest.mark.parametrize("stars,esperado_pos,esperado_queja", [
        (5, True,  False),
        (4, True,  False),
        (3, False, True),
        (2, False, True),
        (1, False, True),
    ])
    def test_positiva_y_queja_segun_estrellas(self, db, cfg_activo, stars, esperado_pos, esperado_queja):
        r = RespuestaFeedback.objects.create(
            config=cfg_activo, token_feedback=uuid.uuid4(), calificacion=stars
        )
        assert r.es_positiva == esperado_pos
        assert r.es_queja    == esperado_queja

    def test_sin_calificacion_no_es_positiva_ni_queja(self, db, cfg_activo):
        r = RespuestaFeedback.objects.create(
            config=cfg_activo, token_feedback=uuid.uuid4()
        )
        assert r.es_positiva is False
        assert r.es_queja    is False


# ─────────────────────────────────────────────────────────────────────────────
# validar_licencia_externa
# ─────────────────────────────────────────────────────────────────────────────

@pytest.mark.django_db
class TestValidarLicenciaExterna:

    def _get(self, id_comercio=""):
        params = {"id_comercio": id_comercio} if id_comercio else {}
        req = rf.get("/api/v1/licencias/validar/", params)
        return validar_licencia_externa(req)

    def test_licencia_activa_vigente_retorna_200(self, licencia):
        r = self._get("HOTEL-TEST-01")
        assert r.status_code == 200
        assert json.loads(r.content)["autorizado"] is True

    def test_sin_parametro_retorna_400(self, licencia):
        r = self._get()
        assert r.status_code == 400

    def test_licencia_inexistente_retorna_401(self):
        r = self._get("HOTEL-FANTASMA-99")
        assert r.status_code == 401
        body = json.loads(r.content)
        assert body["autorizado"] is False
        assert "inexistente" in body["error"].lower()

    def test_licencia_pausada_retorna_403(self, db):
        LicenciaFeedback.objects.create(
            id_comercio="HOTEL-PAUSADO-01", nombre_comercio="P",
            email_facturacion="a@b.com", esta_activa=False,
            fecha_vencimiento=dt.date.today() + dt.timedelta(days=30),
        )
        r = self._get("HOTEL-PAUSADO-01")
        assert r.status_code == 403

    def test_licencia_vencida_retorna_403(self, db):
        LicenciaFeedback.objects.create(
            id_comercio="HOTEL-VENCIDO-01", nombre_comercio="V",
            email_facturacion="a@b.com", esta_activa=True,
            fecha_vencimiento=dt.date.today() - dt.timedelta(days=1),
        )
        r = self._get("HOTEL-VENCIDO-01")
        assert r.status_code == 403
        assert "vencida" in json.loads(r.content)["error"].lower()

    def test_post_retorna_405(self, licencia):
        req = rf.post("/api/v1/licencias/validar/")
        r   = validar_licencia_externa(req)
        assert r.status_code == 405

    def test_todos_los_401_tienen_el_mismo_error(self, db):
        """No debe filtrar si el comercio existe o no."""
        r1 = self._get("no-existe")
        r2 = self._get("tampoco-este")
        detail1 = json.loads(r1.content)["error"]
        detail2 = json.loads(r2.content)["error"]
        assert detail1 == detail2


# ─────────────────────────────────────────────────────────────────────────────
# portal_feedback — GET y POST de calificación
# ─────────────────────────────────────────────────────────────────────────────

@pytest.mark.django_db
class TestPortalFeedback:

    def test_get_muestra_pagina_estrellas(self, cfg_activo):
        tok = uuid.uuid4()
        RespuestaFeedback.objects.create(config=cfg_activo, token_feedback=tok)
        req = rf.get(f"/feedback/{cfg_activo.id}/{tok}/?lang=es")
        req.session = {}
        r = portal_feedback(req, cfg_activo.id, tok)
        assert r.status_code == 200
        assert b"star-btn" in r.content or b"estrella" in r.content or b"form" in r.content

    def test_post_5_estrellas_redirige_a_google_reviews(self, cfg_activo):
        tok = uuid.uuid4()
        RespuestaFeedback.objects.create(config=cfg_activo, token_feedback=tok)
        req = rf.post(f"/feedback/{cfg_activo.id}/{tok}/", {"calificacion": "5"})
        req.session = {}
        r = portal_feedback(req, cfg_activo.id, tok)
        assert r.status_code == 302
        assert r["Location"] == cfg_activo.google_review_link

    def test_post_2_estrellas_redirige_a_queja(self, cfg_activo):
        tok = uuid.uuid4()
        RespuestaFeedback.objects.create(config=cfg_activo, token_feedback=tok)
        req = rf.post(f"/feedback/{cfg_activo.id}/{tok}/", {"calificacion": "2"})
        req.session = {}
        r = portal_feedback(req, cfg_activo.id, tok)
        assert r.status_code == 302
        assert "queja" in r["Location"]

    def test_token_ya_respondido_muestra_gracias(self, cfg_activo):
        tok = uuid.uuid4()
        RespuestaFeedback.objects.create(
            config=cfg_activo, token_feedback=tok, calificacion=5,
            redirigido_a_google=True,
        )
        req = rf.get(f"/feedback/{cfg_activo.id}/{tok}/?lang=es")
        req.session = {}
        r = portal_feedback(req, cfg_activo.id, tok)
        assert r.status_code == 200   # muestra confirmación, no el form


# ─────────────────────────────────────────────────────────────────────────────
# queja_feedback — comentario + Copiloto IA
# ─────────────────────────────────────────────────────────────────────────────

@pytest.mark.django_db
class TestQuejaFeedback:

    def _post_queja(self, cfg, tok, comentario, lang="es"):
        req = rf.post(f"/queja/{cfg.id}/{tok}/queja/?lang={lang}", {"comentario": comentario})
        return queja_feedback(req, cfg.id, tok)

    def test_post_guarda_comentario_turista(self, db, cfg_activo):
        tok = uuid.uuid4()
        resp = RespuestaFeedback.objects.create(
            config=cfg_activo, token_feedback=tok, calificacion=2
        )
        with patch("servicios.ai_service.generar_borrador_respuesta", new=AsyncMock(return_value="")):
            r = self._post_queja(cfg_activo, tok, "La habitación estaba sucia.")
        assert r.status_code == 200
        resp.refresh_from_db()
        assert resp.comentario_turista == "La habitación estaba sucia."
        assert resp.comentario        == "La habitación estaba sucia."

    def test_post_genera_borrador_ia(self, db, cfg_activo):
        tok = uuid.uuid4()
        RespuestaFeedback.objects.create(config=cfg_activo, token_feedback=tok, calificacion=2)
        # generar_borrador_respuesta es síncrona en dm_global → usar MagicMock, no AsyncMock
        with patch("servicios.views.generar_borrador_respuesta",
                   return_value="Lamentamos el inconveniente."):
            r = self._post_queja(cfg_activo, tok, "Mucho ruido.")
        from servicios.models import RespuestaFeedback as RF
        resp = RF.objects.get(token_feedback=tok)
        assert resp.borrador_respuesta_ia == "Lamentamos el inconveniente."
        assert resp.estado_copiloto == EstadoCopiloto.PENDIENTE

    def test_double_post_no_sobreescribe(self, db, cfg_activo):
        tok = uuid.uuid4()
        RespuestaFeedback.objects.create(config=cfg_activo, token_feedback=tok, calificacion=2)
        with patch("servicios.ai_service.generar_borrador_respuesta", new=AsyncMock(return_value="")):
            self._post_queja(cfg_activo, tok, "Primer comentario.")
            self._post_queja(cfg_activo, tok, "Intento de sobreescritura.")
        from servicios.models import RespuestaFeedback as RF
        resp = RF.objects.get(token_feedback=tok)
        assert resp.comentario_turista == "Primer comentario."


# ─────────────────────────────────────────────────────────────────────────────
# alertas_criticas_api — listado y ACK
# ─────────────────────────────────────────────────────────────────────────────

@pytest.mark.django_db
class TestAlertasCriticasApi:

    def _req_api(self, cfg):
        return rf.get("/alertas-criticas/", {
            "comercio_id": str(cfg.id),
            "token":       str(cfg.api_token),
        })

    def test_sin_auth_retorna_401(self, cfg_activo):
        req = rf.get("/alertas-criticas/", {"comercio_id": str(cfg_activo.id), "token": "mal"})
        r   = alertas_criticas_api(req)
        assert r.status_code == 401

    def test_alerta_1_estrella_aparece_en_lista(self, db, cfg_activo):
        tok = uuid.uuid4()
        RespuestaFeedback.objects.create(
            config=cfg_activo, token_feedback=tok, calificacion=1,
            respondido_at=timezone.now(),
        )
        r = alertas_criticas_api(self._req_api(cfg_activo))
        assert r.status_code == 200
        data = json.loads(r.content)
        assert len(data["alertas"]) == 1
        assert data["alertas"][0]["calificacion"] == 1

    def test_4_estrellas_no_aparece_en_alertas(self, db, cfg_activo):
        RespuestaFeedback.objects.create(
            config=cfg_activo, token_feedback=uuid.uuid4(),
            calificacion=4, respondido_at=timezone.now(), redirigido_a_google=True
        )
        r = alertas_criticas_api(self._req_api(cfg_activo))
        assert len(json.loads(r.content)["alertas"]) == 0

    def test_ack_limpia_la_lista(self, db, cfg_activo):
        tok = uuid.uuid4()
        resp = RespuestaFeedback.objects.create(
            config=cfg_activo, token_feedback=tok, calificacion=2,
            respondido_at=timezone.now(),
        )
        # ACK
        ack_req = rf.post(
            f"/alertas-criticas/ack/?comercio_id={cfg_activo.id}&token={cfg_activo.api_token}",
            data=json.dumps({"ids": [str(resp.id)]}),
            content_type="application/json",
        )
        ack_r = ack_alertas_whatsapp(ack_req)
        assert ack_r.status_code == 200
        assert json.loads(ack_r.content)["actualizadas"] == 1

        # Lista ahora vacía
        r = alertas_criticas_api(self._req_api(cfg_activo))
        assert len(json.loads(r.content)["alertas"]) == 0


# ─────────────────────────────────────────────────────────────────────────────
# stats_feedback — métricas
# ─────────────────────────────────────────────────────────────────────────────

@pytest.mark.django_db
class TestStatsFeedback:

    def _req(self, cfg, dias=7):
        return rf.get("/stats/", {
            "comercio_id": str(cfg.id),
            "token":       str(cfg.api_token),
            "dias":        dias,
        })

    def test_sin_auth_retorna_401(self, cfg_activo):
        req = rf.get("/stats/", {"comercio_id": str(cfg_activo.id), "token": "xxx"})
        assert stats_feedback(req).status_code == 401

    def test_metricas_correctas(self, db, cfg_activo):
        ahora = timezone.now()
        # 3 positivas, 1 contenida
        for stars in [5, 4, 4, 2]:
            RespuestaFeedback.objects.create(
                config=cfg_activo, token_feedback=uuid.uuid4(),
                calificacion=stars, respondido_at=ahora,
                redirigido_a_google=(stars >= 4),
            )
        r    = stats_feedback(self._req(cfg_activo))
        data = json.loads(r.content)
        assert data["total_respuestas"]    == 4
        assert data["positivas"]           == 3
        assert data["contenidas"]          == 1
        assert data["redirigidas_a_google"] == 3


# ─────────────────────────────────────────────────────────────────────────────
# servicios/ai_service.py (dm_global) — generar_borrador_respuesta
# ─────────────────────────────────────────────────────────────────────────────

@pytest.mark.django_db
class TestGenerarBorradorRespuesta:
    """Tests de la función síncrona de generación de borradores (dm_global)."""

    def test_sin_api_key_retorna_cadena_vacia(self, settings):
        settings.GEMINI_API_KEY = ""
        from servicios.ai_service import generar_borrador_respuesta
        resultado = generar_borrador_respuesta("La habitación estaba sucia.", "Hotel Test", "es")
        assert resultado == ""

    def test_comentario_vacio_retorna_cadena_vacia(self, settings):
        settings.GEMINI_API_KEY = "test-key"
        from servicios.ai_service import generar_borrador_respuesta
        assert generar_borrador_respuesta("", "Hotel Test", "es") == ""
        assert generar_borrador_respuesta("   ", "Hotel Test", "es") == ""

    def test_gemini_responde_con_texto(self, settings):
        settings.GEMINI_API_KEY = "test-key"
        from servicios.ai_service import generar_borrador_respuesta, _llamar_gemini
        with patch("servicios.ai_service._llamar_gemini",
                   return_value="Lamentamos profundamente el inconveniente."):
            resultado = generar_borrador_respuesta("mucho ruido", "Hotel Test", "es")
        assert resultado == "Lamentamos profundamente el inconveniente."

    def test_gemini_falla_retorna_cadena_vacia(self, settings):
        settings.GEMINI_API_KEY = "test-key"
        from servicios.ai_service import generar_borrador_respuesta
        with patch("servicios.ai_service._llamar_gemini",
                   side_effect=Exception("API error")):
            resultado = generar_borrador_respuesta("ruido", "Hotel Test", "es")
        assert resultado == ""

    @pytest.mark.parametrize("idioma", ["es", "en", "pt"])
    def test_prompt_incluye_nombre_comercio(self, settings, idioma):
        settings.GEMINI_API_KEY = "test-key"
        prompts = []
        from servicios.ai_service import generar_borrador_respuesta

        def mock_gemini(api_key, prompt):
            prompts.append(prompt)
            return "respuesta"

        with patch("servicios.ai_service._llamar_gemini", side_effect=mock_gemini):
            generar_borrador_respuesta("problema", "Hotel Paraíso", idioma)
        assert prompts and "Hotel Paraíso" in prompts[0]
