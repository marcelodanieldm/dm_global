"""
Configuración de pytest para el proyecto Django dm_global.

Usa pytest-django: cada test corre en su propia transacción con rollback,
usando SQLite en memoria (configurado en tests/settings_test.py).
"""
