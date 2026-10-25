#!/usr/bin/env bash
# Switch fightback alert emails from SMTP to the Gmail app (the account already signed in on the phone).
# Rewrites the affected sources in ~/git/fightback, removes the SMTP code/dependencies and commits.
set -euo pipefail

REPO="${REPO:-$HOME/git/fightback}"
SRC="$REPO/app/src/main/java/com/techducat/fightback"
[[ -d "$SRC" ]] || { echo "ERROR: $SRC not found (set REPO=...)" >&2; exit 1; }
cd "$REPO"

if ! git diff --quiet || ! git diff --cached --quiet; then
  echo "NOTE: you have uncommitted changes; they will be included in the commit below."
fi
echo 'writing Mail.kt'
cat > "$SRC/Mail.kt" <<'FIGHTBACK_EOF'
package com.techducat.fightback

import android.content.Intent
import android.net.Uri

object Mail {
    const val GMAIL = "com.google.android.gm"

    /** Opens a pre-filled Gmail compose screen (uses the account currently active in the Gmail app). */
    fun composeIntent(to: String, subject: String, body: String): Intent =
        Intent(Intent.ACTION_SENDTO, Uri.parse("mailto:")).apply {
            putExtra(Intent.EXTRA_EMAIL, arrayOf(to))
            putExtra(Intent.EXTRA_SUBJECT, subject)
            putExtra(Intent.EXTRA_TEXT, body)
            setPackage(GMAIL)
            addFlags(Intent.FLAG_ACTIVITY_NEW_TASK)
        }
}
FIGHTBACK_EOF
echo 'writing Notifier.kt'
cat > "$SRC/Notifier.kt" <<'FIGHTBACK_EOF'
package com.techducat.fightback

import android.app.NotificationChannel
import android.app.NotificationManager
import android.app.PendingIntent
import android.content.Context
import android.content.Intent
import androidx.core.app.NotificationCompat
import androidx.core.app.NotificationManagerCompat

object Notifier {
    private const val CH = "fightback_alerts"

    /** [tapToSend]: optional pre-filled Gmail compose intent, so one tap + Send works as a manual fallback. */
    fun alert(ctx: Context, title: String, text: String, tapToSend: Intent? = null) {
        val nm = ctx.getSystemService(NotificationManager::class.java)
        nm.createNotificationChannel(NotificationChannel(CH, "Failure alerts", NotificationManager.IMPORTANCE_HIGH))
        val b = NotificationCompat.Builder(ctx, CH)
            .setSmallIcon(android.R.drawable.stat_notify_error)
            .setContentTitle(title)
            .setContentText(text)
            .setStyle(NotificationCompat.BigTextStyle().bigText(text))
            .setAutoCancel(true)
        if (tapToSend != null) {
            b.setContentIntent(
                PendingIntent.getActivity(
                    ctx, (System.currentTimeMillis() and 0xFFFFFFF).toInt(), tapToSend,
                    PendingIntent.FLAG_IMMUTABLE or PendingIntent.FLAG_UPDATE_CURRENT
                )
            )
        }
        try { NotificationManagerCompat.from(ctx).notify(System.currentTimeMillis().toInt(), b.build()) }
        catch (_: SecurityException) { /* POST_NOTIFICATIONS not granted */ }
    }
}
FIGHTBACK_EOF
echo 'writing Reporter.kt'
cat > "$SRC/Reporter.kt" <<'FIGHTBACK_EOF'
package com.techducat.fightback

import android.content.Context
import org.json.JSONArray
import org.json.JSONObject
import java.util.Date

/**
 * Records a run result and, on failure, queues an alert email and raises a notification.
 * The queued email is sent by CopyAccessibilityService through the Gmail app.
 */
object Reporter {
    private val lock = Any()
    private const val MAX_QUEUE = 20

    fun record(ctx: Context, ok: Boolean, detail: String, done: (() -> Unit)? = null) {
        val app = ctx.applicationContext
        val snap = Stats.record(app, ok, detail)
        if (!ok) {
            val to = Store.get(app, Store.K_ALERT_TO, Store.DEF_ALERT_TO)
            val subject = "fightback FAILED: ${detail.take(80)}"
            val body = """
                The scheduled select-all + copy did not complete.

                Time:                 ${Date()}
                Reason:               $detail
                Notes app / title:    ${Store.get(app, Store.K_PKG, Store.DEF_PKG)} / "${Store.get(app, Store.K_TITLE, Store.DEF_TITLE)}"
                Success rate:         ${snap.rateText()}
                Consecutive failures: ${snap.consecutiveFailures}
            """.trimIndent()
            enqueue(app, subject, body)
            Notifier.alert(
                app, "fightback: copy failed",
                "$detail\nSuccess rate ${snap.rateText()}\nTap to send the alert email manually.",
                Mail.composeIntent(to, subject, body)
            )
            CopyAccessibilityService.instance?.flushMail()
        }
        done?.invoke()
    }

    fun enqueue(c: Context, subject: String, body: String) = synchronized(lock) {
        val items = readQueue(c) + (subject to body)
        val arr = JSONArray()
        items.takeLast(MAX_QUEUE).forEach { arr.put(JSONObject().put("s", it.first).put("b", it.second)) }
        Store.put(c, "pending", arr.toString())
    }

    fun peekPending(c: Context): Pair<String, String>? = synchronized(lock) { readQueue(c).firstOrNull() }

    fun dropFirst(c: Context) = synchronized(lock) {
        val arr = JSONArray()
        readQueue(c).drop(1).forEach { arr.put(JSONObject().put("s", it.first).put("b", it.second)) }
        Store.put(c, "pending", arr.toString())
    }

    fun pendingCount(c: Context) = synchronized(lock) { readQueue(c).size }

    private fun readQueue(c: Context): List<Pair<String, String>> {
        val a = JSONArray(Store.get(c, "pending", "[]"))
        return (0 until a.length()).map { a.getJSONObject(it).let { o -> o.getString("s") to o.getString("b") } }
    }
}
FIGHTBACK_EOF
echo 'writing CopyAccessibilityService.kt'
cat > "$SRC/CopyAccessibilityService.kt" <<'FIGHTBACK_EOF'
package com.techducat.fightback

import android.accessibilityservice.AccessibilityService
import android.app.KeyguardManager
import android.content.Intent
import android.os.Bundle
import android.os.PowerManager
import android.view.accessibility.AccessibilityEvent
import android.view.accessibility.AccessibilityNodeInfo
import kotlinx.coroutines.CancellationException
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.Job
import kotlinx.coroutines.SupervisorJob
import kotlinx.coroutines.delay
import kotlinx.coroutines.launch
import kotlinx.coroutines.withTimeoutOrNull
import java.text.SimpleDateFormat
import java.util.Date
import java.util.Locale

/**
 * 1) Copy run: launch notes app -> open note by title -> focus body -> select all -> ACTION_COPY.
 *    A watchdog (RUN_TIMEOUT_MS) turns any hang into a reported "stuck" failure.
 * 2) Alert mail: sends queued alerts through the Gmail app (account active in Gmail) by opening a
 *    pre-filled compose screen and pressing Send.
 */
class CopyAccessibilityService : AccessibilityService() {

    companion object {
        @Volatile var instance: CopyAccessibilityService? = null
        private const val RUN_TIMEOUT_MS = 60_000L
        private const val MAIL_TIMEOUT_MS = 120_000L
        private const val MAX_LIST_SCROLLS = 8
    }

    private class Outcome(val ok: Boolean, val detail: String)

    private val scope = CoroutineScope(SupervisorJob() + Dispatchers.Main)
    private var job: Job? = null
    private var mailJob: Job? = null
    @Volatile private var step = "idle"

    override fun onServiceConnected() { instance = this; flushMail() }
    override fun onUnbind(intent: Intent?): Boolean {
        instance = null; job?.cancel(); mailJob?.cancel(); return super.onUnbind(intent)
    }
    override fun onAccessibilityEvent(event: AccessibilityEvent?) {}
    override fun onInterrupt() {}

    @Suppress("DEPRECATION")
    private fun screenLock(ms: Long) = getSystemService(PowerManager::class.java)
        .newWakeLock(PowerManager.SCREEN_BRIGHT_WAKE_LOCK or PowerManager.ACQUIRE_CAUSES_WAKEUP, "fightback:run")
        .apply { acquire(ms) }

    private fun now() = SimpleDateFormat("HH:mm", Locale.US).format(Date())

    // ------------------------------------------------------------------ copy run

    fun startRun() {
        mailJob?.cancel()
        val stuck = job?.isActive == true
        val stuckStep = step
        if (stuck) job?.cancel()
        val wl = screenLock(RUN_TIMEOUT_MS + 10_000)
        job = scope.launch {
            if (stuck) Reporter.record(this@CopyAccessibilityService, false, "previous run still active, stuck at step '$stuckStep'")
            val out = try {
                withTimeoutOrNull(RUN_TIMEOUT_MS) { execute() }
                    ?: Outcome(false, "timed out after ${RUN_TIMEOUT_MS / 1000}s, stuck at step '$step'")
            } catch (e: CancellationException) {
                throw e
            } catch (t: Throwable) {
                Outcome(false, "exception at step '$step': ${t.javaClass.simpleName}: ${t.message}")
            } finally {
                if (wl.isHeld) wl.release()
            }
            Reporter.record(this@CopyAccessibilityService, out.ok, out.detail)
            step = "idle"
            flushMail(afterRun = true)
        }
    }

    /** Wakes the screen and dismisses a non-secure keyguard. Returns an error message, or null when ready. */
    private suspend fun ensureAwake(): String? {
        val pm = getSystemService(PowerManager::class.java)
        val km = getSystemService(KeyguardManager::class.java)
        if (!pm.isInteractive || km.isKeyguardLocked) {
            startActivity(Intent(this, WakeActivity::class.java).addFlags(Intent.FLAG_ACTIVITY_NEW_TASK))
            var waited = 0
            while ((!pm.isInteractive || km.isKeyguardLocked) && waited < 8_000) { delay(500); waited += 500 }
            if (km.isKeyguardLocked)
                return "could not unlock: a PIN/pattern/password is set. " +
                    "Set the screen lock to None or Swipe, or enable Developer options > Stay awake"
        }
        return null
    }

    private suspend fun execute(): Outcome {
        step = "wake / unlock"
        ensureAwake()?.let { return Outcome(false, it) }

        val pkg = Store.get(this, Store.K_PKG, Store.DEF_PKG)
        val title = Store.get(this, Store.K_TITLE, Store.DEF_TITLE).trim()

        // Only look at the notes app and Gmail.
        serviceInfo = serviceInfo?.also { it.packageNames = arrayOf(pkg, Mail.GMAIL) }

        step = "launch"
        val launch = packageManager.getLaunchIntentForPackage(pkg)
            ?: return Outcome(false, "notes app $pkg is not installed")
        launch.addFlags(Intent.FLAG_ACTIVITY_NEW_TASK or Intent.FLAG_ACTIVITY_CLEAR_TASK)
        startActivity(launch)

        var scrolls = 0
        while (true) {
            delay(700)
            val root = rootInActiveWindow ?: continue
            if (root.packageName?.toString() != pkg) continue

            val editables = mutableListOf<AccessibilityNodeInfo>()
            collect(root, editables) { it.isEditable }
            val titleField = editables.firstOrNull {
                !it.isShowingHintText && it.text?.toString()?.trim().equals(title, ignoreCase = true)
            }

            if (titleField == null) {
                step = "find note"
                val hit = root.findAccessibilityNodeInfosByText(title)
                    .firstOrNull { it.text?.toString()?.trim().equals(title, ignoreCase = true) }
                if (hit != null) {
                    var n: AccessibilityNodeInfo? = hit
                    while (n != null && !n.isClickable) n = n.parent
                    if (n == null || !n.performAction(AccessibilityNodeInfo.ACTION_CLICK))
                        return Outcome(false, "found '$title' but could not click it")
                    step = "open note"
                    delay(1200)
                    continue
                }
                val list = ArrayList<AccessibilityNodeInfo>()
                collect(root, list) { it.isScrollable }
                if (list.isEmpty() || scrolls >= MAX_LIST_SCROLLS)
                    return Outcome(false, "note titled '$title' not found")
                list.first().performAction(AccessibilityNodeInfo.ACTION_SCROLL_FORWARD)
                scrolls++
                continue
            }

            step = "locate body"
            val body = editables.filter { it !== titleField && !it.isShowingHintText }
                .maxByOrNull { it.text?.length ?: 0 }
                ?: return Outcome(false, "note is open but body is empty / not found")
            val len = body.text?.length ?: 0
            if (len == 0) return Outcome(false, "note body is empty")

            step = "select all"
            body.performAction(AccessibilityNodeInfo.ACTION_FOCUS)
            delay(300)
            val args = Bundle().apply {
                putInt(AccessibilityNodeInfo.ACTION_ARGUMENT_SELECTION_START_INT, 0)
                putInt(AccessibilityNodeInfo.ACTION_ARGUMENT_SELECTION_END_INT, len)
            }
            val selOk = body.performAction(AccessibilityNodeInfo.ACTION_SET_SELECTION, args)
            delay(300)
            body.refresh()
            if (!selOk || body.textSelectionStart != 0 || body.textSelectionEnd != len)
                return Outcome(false, "select-all failed (selection ${body.textSelectionStart}-${body.textSelectionEnd} of $len)")

            step = "copy"
            val copied = body.performAction(AccessibilityNodeInfo.ACTION_COPY)
            delay(300)
            performGlobalAction(GLOBAL_ACTION_BACK)
            return if (copied) Outcome(true, "copied $len chars") else Outcome(false, "ACTION_COPY returned false")
        }
    }

    // ------------------------------------------------------------------ alert mail via Gmail

    /** Sends queued alerts. Called after failures, when the service connects, and by "Send test email". */
    fun flushMail(afterRun: Boolean = false) {
        if (!afterRun && job?.isActive == true) return        // the run flushes when it ends
        if (mailJob?.isActive == true || Reporter.pendingCount(this) == 0) return
        mailJob = scope.launch {
            val wl = screenLock(MAIL_TIMEOUT_MS + 10_000)
            try {
                val done = withTimeoutOrNull(MAIL_TIMEOUT_MS) { sendQueued() }
                if (done == null) Store.put(this@CopyAccessibilityService, "mail_last", "timed out at ${now()}")
            } finally {
                if (wl.isHeld) wl.release()
                step = "idle"
            }
        }
    }

    private suspend fun sendQueued() {
        step = "mail"
        ensureAwake()?.let { Store.put(this, "mail_last", "not sent at ${now()}: $it"); return }
        while (true) {
            val (subject, body) = Reporter.peekPending(this) ?: break
            if (!sendViaGmail(subject, body)) {
                Store.put(this, "mail_last", "FAILED at ${now()}: Gmail compose did not send (tap the alert notification to send manually)")
                return
            }
            Reporter.dropFirst(this)
            Store.put(this, "mail_last", "sent at ${now()}")
        }
    }

    private suspend fun sendViaGmail(subject: String, body: String): Boolean {
        val to = Store.get(this, Store.K_ALERT_TO, Store.DEF_ALERT_TO)
        serviceInfo = serviceInfo?.also {
            it.packageNames = arrayOf(Store.get(this, Store.K_PKG, Store.DEF_PKG), Mail.GMAIL)
        }
        startActivity(Mail.composeIntent(to, subject, body))

        var clicked = false
        var waited = 0
        while (waited < 20_000) {
            delay(700); waited += 700
            val root = rootInActiveWindow ?: continue
            val send = if (root.packageName?.toString() == Mail.GMAIL) findSend(root) else null
            if (send == null) {
                if (clicked) return true        // compose screen is gone -> message was sent
                continue
            }
            if (!clicked) {
                var n: AccessibilityNodeInfo? = send
                while (n != null && !n.isClickable) n = n.parent
                if (n != null && n.performAction(AccessibilityNodeInfo.ACTION_CLICK)) {
                    clicked = true
                    delay(1000)
                }
            }
        }
        return false
    }

    private fun findSend(root: AccessibilityNodeInfo): AccessibilityNodeInfo? {
        root.findAccessibilityNodeInfosByViewId("com.google.android.gm:id/send").firstOrNull()?.let { return it }
        return root.findAccessibilityNodeInfosByText("Send").firstOrNull {
            (it.contentDescription ?: it.text)?.toString().equals("Send", ignoreCase = true)
        }
    }

    private fun collect(n: AccessibilityNodeInfo?, out: MutableList<AccessibilityNodeInfo>, pred: (AccessibilityNodeInfo) -> Boolean) {
        if (n == null) return
        if (pred(n)) out.add(n)
        for (i in 0 until n.childCount) collect(n.getChild(i), out, pred)
    }
}
FIGHTBACK_EOF
echo 'writing MainActivity.kt'
cat > "$SRC/MainActivity.kt" <<'FIGHTBACK_EOF'
package com.techducat.fightback

import android.Manifest
import android.app.Activity
import android.app.KeyguardManager
import android.content.Intent
import android.net.Uri
import android.os.Build
import android.os.Bundle
import android.provider.Settings
import android.widget.Button
import android.widget.EditText
import android.widget.LinearLayout
import android.widget.ScrollView
import android.widget.TextView
import android.widget.Toast
import java.text.SimpleDateFormat
import java.util.Date
import java.util.Locale

class MainActivity : Activity() {
    private lateinit var status: TextView
    private val fields = LinkedHashMap<String, EditText>()

    private fun dp(v: Int) = (v * resources.displayMetrics.density).toInt()

    override fun onCreate(savedInstanceState: Bundle?) {
        super.onCreate(savedInstanceState)
        val col = LinearLayout(this).apply { orientation = LinearLayout.VERTICAL; setPadding(dp(16), dp(16), dp(16), dp(32)) }
        setContentView(ScrollView(this).apply { addView(col) })

        status = TextView(this).apply { textSize = 14f; typeface = android.graphics.Typeface.MONOSPACE }
        col.addView(status)

        fun field(key: String, label: String, def: String) {
            col.addView(TextView(this).apply { text = label; setPadding(0, dp(12), 0, 0) })
            val e = EditText(this).apply { setText(Store.get(this@MainActivity, key, def)); setSingleLine() }
            fields[key] = e; col.addView(e)
        }
        fun btn(label: String, click: () -> Unit) = col.addView(Button(this).apply { text = label; setOnClickListener { click() } })

        field(Store.K_PKG, "Notes app package", Store.DEF_PKG)
        field(Store.K_TITLE, "Note title", Store.DEF_TITLE)
        field(Store.K_ALERT_TO, "Send alerts to (via the Gmail app's active account)", Store.DEF_ALERT_TO)

        btn("Save settings") { save(); toast("Saved") }
        btn("1. Enable accessibility service") { startActivity(Intent(Settings.ACTION_ACCESSIBILITY_SETTINGS)) }
        btn("2. Allow exact alarms") {
            if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.S)
                startActivity(Intent(Settings.ACTION_REQUEST_SCHEDULE_EXACT_ALARM, Uri.parse("package:$packageName")))
        }
        btn("3. Disable battery optimisation") { startActivity(Intent(Settings.ACTION_IGNORE_BATTERY_OPTIMIZATION_SETTINGS)) }
        btn("4. Developer options (turn on 'Stay awake')") {
            try { startActivity(Intent(Settings.ACTION_APPLICATION_DEVELOPMENT_SETTINGS)) }
            catch (_: Exception) { toast("Enable Developer options first (tap Build number 7 times)") }
        }
        btn("Start / stop hourly schedule (HH:59)") {
            save()
            val on = !Store.getB(this, Store.K_ENABLED)
            Store.putB(this, Store.K_ENABLED, on)
            if (on && !Scheduler.schedule(this)) { Store.putB(this, Store.K_ENABLED, false); toast("Allow exact alarms first") }
            if (!on) Scheduler.cancel(this)
            refresh()
        }
        btn("Run now (test)") {
            save()
            val svc = CopyAccessibilityService.instance
            if (svc == null) toast("Accessibility service not enabled") else { svc.startRun(); toast("Running…") }
        }
        btn("Send test email (via Gmail app)") {
            save()
            val svc = CopyAccessibilityService.instance
            if (svc == null) toast("Accessibility service not enabled") else {
                Reporter.enqueue(this, "fightback test", "Alerts are working. ${Date()}")
                svc.flushMail(); toast("Sending via Gmail…")
            }
        }
        btn("Reset statistics") { Stats.reset(this); refresh() }

        if (Build.VERSION.SDK_INT >= 33) requestPermissions(arrayOf(Manifest.permission.POST_NOTIFICATIONS), 1)
    }

    override fun onResume() { super.onResume(); refresh() }

    private fun save() = fields.forEach { (k, v) -> Store.put(this, k, v.text.toString().trim()) }
    private fun toast(s: String) = Toast.makeText(this, s, Toast.LENGTH_SHORT).show()

    private fun refresh() {
        val s = Stats.snap(this)
        val fmt = SimpleDateFormat("EEE HH:mm", Locale.getDefault())
        val enabled = Store.getB(this, Store.K_ENABLED)
        val secure = getSystemService(KeyguardManager::class.java).isDeviceSecure
        status.text = buildString {
            appendLine("Schedule:      ${if (enabled) "ON, next ${fmt.format(Date(Scheduler.nextTrigger()))}" else "OFF"}")
            appendLine("Accessibility: ${if (CopyAccessibilityService.instance != null) "connected" else "NOT enabled"}")
            appendLine("Exact alarms:  ${if (Scheduler.canScheduleExact(this@MainActivity)) "allowed" else "NOT allowed"}")
            appendLine("Screen lock:   ${if (secure) "SECURE - unlock will fail; set None/Swipe" else "none/swipe - OK"}")
            appendLine("Success rate:  ${s.rateText()}")
            appendLine("Consec. fails: ${s.consecutiveFailures}")
            appendLine("Alerts queued: ${Reporter.pendingCount(this@MainActivity)}")
            appendLine("Alert mail:    ${Store.get(this@MainActivity, "mail_last", "none yet")}")
            appendLine()
            appendLine("Recent runs:")
            Stats.log(this@MainActivity).takeLast(10).reversed().forEach { appendLine(it) }
        }
    }
}
FIGHTBACK_EOF

# remove SMTP code, dependencies, permissions and settings keys
rm -f "$SRC/EmailSender.kt"
sed -i '/android-mail/d;/android-activation/d' app/build.gradle.kts
sed -i '/android.permission.INTERNET/d;/ACCESS_NETWORK_STATE/d' app/src/main/AndroidManifest.xml
sed -i '/K_SMTP_USER/d;/K_SMTP_PASS/d' "$SRC/Store.kt"

if grep -rn "EmailSender\|K_SMTP\|javax.mail" app/src; then
  echo "ERROR: leftover SMTP references (see above)" >&2; exit 1
fi

git add -A
git commit -q -m "Send failure alerts through the Gmail app (signed-in account) instead of SMTP"
echo
echo "Committed. Next:"
echo "  ./build_install_fightback.sh        # rebuild + reinstall (from ~/Downloads)"
echo "  git -C \"$REPO\" push"
