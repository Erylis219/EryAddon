@echo off
title Mise a jour EryAddon
powershell -NoProfile -ExecutionPolicy Bypass -File "%~dp0MettreAJour.ps1" & pause & exit /b
