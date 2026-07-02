from django.contrib import admin
from django.urls import include, path

admin.site.site_header = "DM Global — Servicio de Feedback"
admin.site.site_title = "DM Global Admin"
admin.site.index_title = "Panel de Administración"

urlpatterns = [
    path("admin/", admin.site.urls),
    path("", include("servicios.urls", namespace="servicios")),
]
