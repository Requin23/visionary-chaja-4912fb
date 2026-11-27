# Configuration push Supabase

Le token `sbp_...` est un token personnel Supabase. Ne le mets pas dans `index.html`, `sw.js`, GitHub, Vercel ou le navigateur. Révoque celui que tu as partagé, puis crée-en un nouveau si tu veux utiliser la CLI.

## 1. SQL

Dans Supabase SQL Editor, exécute:

```sql
-- contenu de supabase/migrations/20260601_push_notifications.sql
```

Puis configure uniquement l'URL du projet dans PostgreSQL. Ne stocke pas la service role key dans un paramètre PostgreSQL:

```sql
alter database postgres set app.settings.supabase_url = 'https://TON-PROJET.supabase.co';
select pg_reload_conf();
```

Applique ensuite `20261128_security_hardening_followup.sql`. La migration transfère automatiquement une ancienne clé enregistrée dans `app.settings.service_role_key` vers Supabase Vault. Si aucune ancienne clé n'existe, ajoute la clé dans le coffre Vault de Supabase avec le nom `supabase_service_role_key`. Après la migration, réinitialise l'ancien paramètre dans SQL Editor:

```sql
alter database postgres reset app.settings.service_role_key;
select pg_reload_conf();
```

## 2. Secrets Edge Function

La clé publique VAPID est dans `index.html`. La clé privée VAPID ne doit jamais être commitée; si elle a déjà été poussée sur GitHub, régénère une nouvelle paire VAPID et remplace les secrets Supabase.

```bash
supabase secrets set VAPID_PUBLIC_KEY="TA_VAPID_PUBLIC_KEY"
supabase secrets set VAPID_PRIVATE_KEY="TA_VAPID_PRIVATE_KEY"
supabase secrets set VAPID_SUBJECT="mailto:ton-email@example.com"
```

Important: vérifie que `VAPID_PUBLIC_KEY` dans les secrets est exactement la même valeur que `VAPID_PUBLIC_KEY` dans `index.html`.

## 3. Déploiement

```bash
supabase functions deploy send-push --no-verify-jwt
```

La fonction vérifie elle-même le header `Authorization` avec la service role key, donc elle peut être appelée par le trigger SQL.

## 4. Test

1. Après application de la migration `20261128_security_hardening_followup.sql`, déploie `index.html`, `sw.js`, `manifest.json` et `vercel.json`.
2. Ouvre l'app en HTTPS.
3. Connecte-toi.
4. Active Notifications dans Réglages.
5. Vérifie dans Supabase que `push_subscriptions` contient une ligne pour ton utilisateur.
6. Insère une notification de test:

```sql
select public.enqueue_notification(
  auth.uid(),
  'system',
  'Test mbife',
  'Les notifications push sont branchees.',
  null,
  '{}'::jsonb
);
```

Pour un test depuis SQL Editor, remplace `auth.uid()` par l'id réel de ton utilisateur.
