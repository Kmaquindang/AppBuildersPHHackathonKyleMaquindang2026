// MainActivity.kt: the whole Libre Android UI. Onboarding (name, then Bluetooth permission),
// chat with bubbles, @libre asks with rule and document chips, read-only Tasks and Knowledge,
// rooms (Town Square, name + code), and a Details sheet that says how a message arrived.
package app.libre.android

import androidx.compose.ui.text.style.TextAlign
import app.libre.core.LinkStatusWords
import android.Manifest
import android.content.Intent
import android.content.pm.PackageManager
import android.os.Build
import android.os.Bundle
import androidx.activity.ComponentActivity
import androidx.activity.compose.rememberLauncherForActivityResult
import androidx.activity.compose.setContent
import androidx.activity.result.contract.ActivityResultContracts
import androidx.compose.foundation.background
import androidx.compose.foundation.clickable
import androidx.compose.foundation.layout.*
import androidx.compose.foundation.lazy.LazyColumn
import androidx.compose.foundation.lazy.items
import androidx.compose.foundation.lazy.rememberLazyListState
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.filled.Add
import androidx.compose.material.icons.filled.Send
import androidx.compose.material3.*
import androidx.compose.runtime.*
import kotlinx.coroutines.launch
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.platform.LocalContext
import androidx.compose.ui.platform.testTag
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.text.style.TextOverflow
import androidx.compose.ui.unit.dp
import androidx.core.content.ContextCompat
import app.libre.core.JoinCode
import app.libre.core.JoinLink
import app.libre.core.RoomState
import app.libre.mesh.DocChip
import app.libre.mesh.Entry
import java.text.SimpleDateFormat
import java.util.Date
import java.util.Locale

val BLE_PERMISSIONS: Array<String> = if (Build.VERSION.SDK_INT >= 31)
    arrayOf(Manifest.permission.BLUETOOTH_SCAN, Manifest.permission.BLUETOOTH_CONNECT, Manifest.permission.BLUETOOTH_ADVERTISE)
else arrayOf(Manifest.permission.ACCESS_FINE_LOCATION)

class MainActivity : ComponentActivity() {
    private val pendingLink = mutableStateOf<JoinLink?>(null)

    override fun onCreate(savedInstanceState: Bundle?) {
        super.onCreate(savedInstanceState)
        handle(intent)
        val app = application as LibreApp
        setContent { LibreTheme { Surface(Modifier.fillMaxSize()) { LibreRoot(app, pendingLink) } } }
    }

    override fun onNewIntent(intent: Intent) { super.onNewIntent(intent); handle(intent) }

    private fun handle(intent: Intent?) {
        intent?.dataString?.let { JoinLink.parse(it) }?.let { pendingLink.value = it }
    }
}

fun hasBlePermissions(ctx: android.content.Context) =
    BLE_PERMISSIONS.all { ContextCompat.checkSelfPermission(ctx, it) == PackageManager.PERMISSION_GRANTED }

@Composable
fun LibreRoot(app: LibreApp, pendingLink: MutableState<JoinLink?>) {
    val profile by app.mesh.profile.collectAsState()
    val ctx = LocalContext.current
    var granted by remember { mutableStateOf(hasBlePermissions(ctx)) }
    LaunchedEffect(profile.onboarded, granted) {
        if (profile.onboarded && granted) {
            app.startBluetooth()
            // Opening Libre restarts the background relay if it was on (Android may have stopped it).
            if (app.backgroundRelay.value) RelayService.start(ctx)
        }
    }
    when {
        !profile.onboarded -> Onboarding { app.completeOnboarding(it) }
        !granted -> PermissionScreen { granted = hasBlePermissions(ctx) }
        else -> MainScreen(app, pendingLink)
    }
}

@Composable
fun Onboarding(done: (String) -> Unit) {
    var name by remember { mutableStateOf("") }
    Column(Modifier.fillMaxSize().padding(28.dp), verticalArrangement = Arrangement.Center) {
        Text("Libre", style = MaterialTheme.typography.displayMedium, color = MaterialTheme.colorScheme.primary, fontWeight = FontWeight.Bold)
        Spacer(Modifier.height(8.dp))
        Text("Chat with people nearby, no internet needed. Ask @libre and the team laptop answers from your rules and documents.")
        Spacer(Modifier.height(24.dp))
        OutlinedTextField(name, { name = it.take(40) }, label = { Text("Your name") }, singleLine = true,
            modifier = Modifier.fillMaxWidth().testTag("name"))
        Spacer(Modifier.height(16.dp))
        Button({ done(name.trim()) }, enabled = name.isNotBlank(), modifier = Modifier.fillMaxWidth()) { Text("Continue") }
    }
}

@Composable
fun PermissionScreen(recheck: () -> Unit) {
    val launcher = rememberLauncherForActivityResult(ActivityResultContracts.RequestMultiplePermissions()) { recheck() }
    Column(Modifier.fillMaxSize().padding(28.dp), verticalArrangement = Arrangement.Center) {
        Text("Find nearby devices", style = MaterialTheme.typography.headlineSmall, fontWeight = FontWeight.Bold)
        Spacer(Modifier.height(8.dp))
        Text(if (Build.VERSION.SDK_INT >= 31)
            "Libre uses Bluetooth to reach nearby iPhones, Macs and Android phones. Android calls this the Nearby devices permission. Libre does not use your location."
        else "Libre uses Bluetooth to reach nearby phones and Macs. On this Android version Bluetooth scanning needs the location permission. Libre does not record your location.")
        Spacer(Modifier.height(20.dp))
        Button({ launcher.launch(BLE_PERMISSIONS) }, modifier = Modifier.fillMaxWidth()) { Text("Allow Bluetooth") }
    }
}

private enum class Tab(val title: String) { CHAT("Chat"), TASKS("Tasks"), KNOWLEDGE("Knowledge") }

@OptIn(ExperimentalMaterial3Api::class)
@Composable
fun MainScreen(app: LibreApp, pendingLink: MutableState<JoinLink?>) {
    val mesh = app.mesh
    val rooms by mesh.rooms.collectAsState()
    val activeId by mesh.activeId.collectAsState()
    val peers by mesh.peers.collectAsState()
    val entries by mesh.entries.collectAsState()
    val problem by mesh.problem.collectAsState()
    var tab by remember { mutableStateOf(Tab.CHAT) }
    var showRooms by remember { mutableStateOf(false) }
    val active = rooms.firstOrNull { it.id == activeId } ?: rooms.firstOrNull()

    Scaffold(
        topBar = {
            CenterAlignedTopAppBar(
                title = {
                    Column(horizontalAlignment = Alignment.CenterHorizontally, modifier = Modifier.clickable { showRooms = true }) {
                        Text(active?.displayName ?: "Libre", fontWeight = FontWeight.SemiBold)
                        // Wraps instead of truncating; shows what is still waiting to send.
                        Text(LinkStatusWords.header(peers.size, entries.count { it.mine && it.sentTo.isEmpty() }),
                            style = MaterialTheme.typography.labelSmall, color = MaterialTheme.colorScheme.onSurfaceVariant,
                            textAlign = TextAlign.Center, softWrap = true)
                    }
                },
                actions = { IconButton({ showRooms = true }) { Icon(Icons.Filled.Add, "Rooms") } })
        },
        bottomBar = {
            NavigationBar {
                Tab.entries.forEach { t ->
                    NavigationBarItem(selected = tab == t, onClick = { tab = t }, icon = {}, label = { Text(t.title) })
                }
            }
        }) { pad ->
        Column(Modifier.padding(pad).fillMaxSize()) {
            problem?.let {
                Text(it, Modifier.fillMaxWidth().background(MaterialTheme.colorScheme.errorContainer).padding(10.dp),
                    color = MaterialTheme.colorScheme.onErrorContainer, style = MaterialTheme.typography.bodySmall)
            }
            if (active?.pending == true) {
                Text("Waiting for the room's admin laptop to let you in. Stay near it.",
                    Modifier.fillMaxWidth().background(MaterialTheme.colorScheme.secondaryContainer).padding(10.dp),
                    style = MaterialTheme.typography.bodySmall)
            }
            when (tab) {
                Tab.CHAT -> ChatPane(app)
                Tab.TASKS -> TasksPane(app)
                Tab.KNOWLEDGE -> KnowledgePane(app)
            }
        }
    }
    if (showRooms) RoomsSheet(app, rooms, activeId, null) { showRooms = false }
    pendingLink.value?.let { link -> RoomsSheet(app, rooms, activeId, link) { pendingLink.value = null } }
}

@Composable
fun ChatPane(app: LibreApp) {
    val entries by app.mesh.entries.collectAsState()
    val waiting by app.mesh.waiting.collectAsState()
    val partials by app.mesh.partials.collectAsState()
    var text by remember { mutableStateOf("") }
    var details by remember { mutableStateOf<Entry?>(null) }
    var doc by remember { mutableStateOf<DocChip?>(null) }
    val list = rememberLazyListState()
    LaunchedEffect(entries.size) { if (entries.isNotEmpty()) list.animateScrollToItem(entries.size - 1) }
    LaunchedEffect(partials) { if (partials.isNotEmpty()) list.scrollToItem(maxOf(0, list.layoutInfo.totalItemsCount - 1)) }
    Column(Modifier.fillMaxSize()) {
        LazyColumn(Modifier.weight(1f).fillMaxWidth().padding(horizontal = 10.dp), state = list) {
            if (entries.isEmpty()) item {
                Text("No messages yet. Say hi, or type @libre and a question for the team laptop.",
                    Modifier.padding(24.dp), color = MaterialTheme.colorScheme.onSurfaceVariant)
            }
            items(entries, key = { it.id }) { e -> Bubble(e, onDetails = { details = e }, onDoc = { doc = it }) }
            // Streamed answers (issue #2): the text so far, replaced by the whole answer when it arrives.
            items(partials, key = { "partial-" + it.askId }) { p -> PartialBubble(p.text) }
            if (waiting.isNotEmpty() && partials.isEmpty()) item {
                Text("Libre is thinking...", Modifier.padding(8.dp), style = MaterialTheme.typography.bodySmall,
                    color = MaterialTheme.colorScheme.onSurfaceVariant)
            }
        }
        Row(Modifier.fillMaxWidth().padding(8.dp), verticalAlignment = Alignment.CenterVertically) {
            OutlinedTextField(text, { text = it }, placeholder = { Text("Message, or @libre to ask") },
                modifier = Modifier.weight(1f).testTag("composer"), shape = RoundedCornerShape(22.dp), maxLines = 4)
            IconButton({ val t = text; text = ""; app.run { it.send(t) } }, enabled = text.isNotBlank()) {
                Icon(Icons.Filled.Send, "Send", tint = MaterialTheme.colorScheme.primary)
            }
        }
    }
    details?.let { DetailsDialog(it) { details = null } }
    doc?.let { d ->
        AlertDialog(onDismissRequest = { doc = null }, confirmButton = { TextButton({ doc = null }) { Text("Done") } },
            title = { Text(d.label) }, text = { Text(d.excerpt.ifEmpty { "No excerpt was sent with this answer." }) })
    }
}

@OptIn(ExperimentalLayoutApi::class)
/** An answer still being written: Libre's bubble with the text so far. Wraps, never cut off. */
@Composable
fun PartialBubble(text: String) {
    val dark = androidx.compose.foundation.isSystemInDarkTheme()
    Column(Modifier.fillMaxWidth().padding(vertical = 3.dp), horizontalAlignment = Alignment.Start) {
        Text("Libre is writing", style = MaterialTheme.typography.labelSmall,
            color = MaterialTheme.colorScheme.onSurfaceVariant, modifier = Modifier.padding(start = 10.dp, bottom = 2.dp))
        Text(text, color = MaterialTheme.colorScheme.onSurface,
            modifier = Modifier.widthIn(max = 300.dp).background(if (dark) LibreColors.IncomingDark else LibreColors.Incoming, RoundedCornerShape(18.dp))
                .padding(horizontal = 12.dp, vertical = 8.dp))
    }
}

@Composable
fun Bubble(e: Entry, onDetails: () -> Unit, onDoc: (DocChip) -> Unit) {
    val dark = androidx.compose.foundation.isSystemInDarkTheme()
    val mineColor = MaterialTheme.colorScheme.primary
    val bg = if (e.mine) mineColor else if (dark) LibreColors.IncomingDark else LibreColors.Incoming
    val fg = if (e.mine) MaterialTheme.colorScheme.onPrimary else MaterialTheme.colorScheme.onSurface
    Column(Modifier.fillMaxWidth().padding(vertical = 3.dp), horizontalAlignment = if (e.mine) Alignment.End else Alignment.Start) {
        if (!e.mine) Text(if (e.isAnswer) "Libre" else (e.senderName ?: e.origin), style = MaterialTheme.typography.labelSmall,
            color = MaterialTheme.colorScheme.onSurfaceVariant, modifier = Modifier.padding(start = 10.dp, bottom = 2.dp))
        Column(Modifier.widthIn(max = 300.dp).background(bg, RoundedCornerShape(18.dp)).clickable { onDetails() }.padding(horizontal = 12.dp, vertical = 8.dp)) {
            Text(e.body, color = fg)
            if (e.isAnswer && (e.rulesUsed.isNotEmpty() || e.docRefs.isNotEmpty())) {
                Spacer(Modifier.height(6.dp))
                FlowRow(horizontalArrangement = Arrangement.spacedBy(6.dp)) {
                    e.rulesUsed.forEach { AssistChip({ onDetails() }, label = { Text(it, maxLines = 1, overflow = TextOverflow.Ellipsis) }) }
                    e.docRefs.forEach { d -> AssistChip({ onDoc(d) }, label = { Text(d.label, maxLines = 1, overflow = TextOverflow.Ellipsis) }) }
                }
            }
            if (e.isAnswer && e.noRule) Text("No team rule covers this yet.", style = MaterialTheme.typography.labelSmall, color = fg)
        }
    }
}

private fun time(ms: Long) = SimpleDateFormat("MMM d, h:mm a", Locale.getDefault()).format(Date(ms))

@Composable
fun DetailsDialog(e: Entry, dismiss: () -> Unit) {
    AlertDialog(onDismissRequest = dismiss, confirmButton = { TextButton(dismiss) { Text("Done") } }, title = { Text("Details") }, text = {
        Column(verticalArrangement = Arrangement.spacedBy(4.dp)) {
            Text("From: " + if (e.mine) "You" else (e.senderName ?: e.origin))
            Text("Sent: " + time(e.createdAt))
            if (!e.mine) Text("Received: " + time(e.receivedAt))
            Text(if (e.mine) "Sent to: " + (e.sentTo.ifEmpty { listOf("queued until someone is nearby") }.joinToString(", "))
                 else "Arrived via " + (e.link ?: "Bluetooth"))
            if (e.hops.isNotEmpty()) Text("Path: " + e.hops.joinToString(" > "))
            e.model?.let { Text("Model: $it") }
            e.proofLine?.let { Text(it) }
            if (e.unverifiedRules.isNotEmpty()) Text("Not checked against this phone's copy: " + e.unverifiedRules.joinToString(", "))
            if (e.backfilled) Text("Caught up from a nearby device")
        }
    })
}

@Composable
fun TasksPane(app: LibreApp) {
    val cache by app.mesh.cache.collectAsState()
    LazyColumn(Modifier.fillMaxSize().padding(16.dp)) {
        item { Text("Tasks come from the team laptop. Read only on Android.", style = MaterialTheme.typography.bodySmall,
            color = MaterialTheme.colorScheme.onSurfaceVariant) }
        if (cache.tasks.isEmpty()) item { Text("No tasks yet.", Modifier.padding(top = 16.dp)) }
        items(cache.tasks, key = { it.id }) { t ->
            ListItem(headlineContent = { Text(t.title) },
                supportingContent = { Text(listOfNotNull(t.assignee, t.due?.let { "due $it" }, t.status).joinToString(" . ")) })
        }
        if (cache.rules.isNotEmpty()) {
            item { Text("Rules", style = MaterialTheme.typography.titleMedium, modifier = Modifier.padding(top = 16.dp)) }
            items(cache.rules.filter { !it.retired }, key = { it.id }) { r ->
                ListItem(headlineContent = { Text(r.citation) }, supportingContent = { Text(r.body, maxLines = 3, overflow = TextOverflow.Ellipsis) })
            }
        }
    }
}

@Composable
fun KnowledgePane(app: LibreApp) {
    val cache by app.mesh.cache.collectAsState()
    LazyColumn(Modifier.fillMaxSize().padding(16.dp)) {
        item { Text("Documents on the team laptop. Ask @libre about them.", style = MaterialTheme.typography.bodySmall,
            color = MaterialTheme.colorScheme.onSurfaceVariant) }
        if (cache.library.isEmpty()) item { Text("No documents listed yet. They appear once the laptop is nearby.", Modifier.padding(top = 16.dp)) }
        items(cache.library) { d ->
            ListItem(headlineContent = { Text(d.title) }, supportingContent = { Text("v${d.version} . ${d.pages} pages") })
        }
    }
}

@OptIn(ExperimentalMaterial3Api::class)
@Composable
fun RoomsSheet(app: LibreApp, rooms: List<RoomState>, activeId: String, link: JoinLink?, dismiss: () -> Unit) {
    var name by remember { mutableStateOf(link?.room ?: "") }
    var code by remember { mutableStateOf(link?.code ?: "") }
    var busy by remember { mutableStateOf(false) }
    var error by remember { mutableStateOf<String?>(null) }
    val scope = rememberCoroutineScope()
    ModalBottomSheet(onDismissRequest = dismiss) {
        Column(Modifier.padding(16.dp).padding(bottom = 24.dp)) {
            Text("Rooms", style = MaterialTheme.typography.titleLarge)
            rooms.forEach { r ->
                ListItem(headlineContent = { Text(r.displayName) },
                    supportingContent = { Text(if (r.pending) "Waiting to be let in" else if (r.isDefault) "Everyone nearby" else "Private room") },
                    trailingContent = { if (r.id == activeId) Text("Open", color = MaterialTheme.colorScheme.primary) },
                    modifier = Modifier.clickable { app.run { it.activate(r.id) }; dismiss() })
            }
            HorizontalDivider(Modifier.padding(vertical = 8.dp))
            Text("Join a room", style = MaterialTheme.typography.titleMedium)
            OutlinedTextField(name, { name = it }, label = { Text("Room name") }, singleLine = true, modifier = Modifier.fillMaxWidth())
            OutlinedTextField(code, { code = it }, label = { Text("Join code (like K7QM-3XRF) or passcode") }, singleLine = true, modifier = Modifier.fillMaxWidth())
            error?.let { Text(it, color = MaterialTheme.colorScheme.error, style = MaterialTheme.typography.bodySmall) }
            Spacer(Modifier.height(8.dp))
            Button(enabled = !busy && name.isNotBlank() && code.isNotBlank(), modifier = Modifier.fillMaxWidth(), onClick = {
                busy = true; error = null
                val n = name; val c = code
                scope.launch {
                    val room = kotlinx.coroutines.withContext(kotlinx.coroutines.Dispatchers.Default) {
                        if (JoinCode.isValid(c)) RoomState.fromCode(n, c) else RoomState.fromPasscode(n, c)
                    }
                    busy = false
                    if (room == null) error = "Check the room name and code."
                    else { app.run { it.join(room) }; dismiss() }
                }
            }) { Text(if (busy) "Unlocking room..." else "Join") }
            HorizontalDivider(Modifier.padding(vertical = 8.dp))
            KeyConflictRows(app)
            TrustMacRow(app)
            BackgroundRelayRow(app)
        }
    }
}

/** Devices that came back with a different Bluetooth key (issue #12), with a way to trust it. */
@Composable
fun KeyConflictRows(app: LibreApp) {
    val conflicts by app.keyConflicts.collectAsState()
    if (conflicts.isEmpty()) return
    Text("Changed device keys", style = MaterialTheme.typography.titleMedium)
    conflicts.forEach { name ->
        Column(Modifier.fillMaxWidth().padding(vertical = 6.dp)) {
            Text("$name came back with a different device key, so Libre is not linking to it over Bluetooth.")
            Text("This is normal after Libre was reinstalled on that device. If it was not reinstalled, another device nearby may be using its name.",
                style = MaterialTheme.typography.bodySmall, color = MaterialTheme.colorScheme.onSurfaceVariant)
            TextButton({ app.trustNewKey(name) }, modifier = Modifier.heightIn(min = 48.dp)) { Text("Trust the new key") }
        }
    }
    HorizontalDivider(Modifier.padding(vertical = 8.dp))
}

/** Town Square moderation (issue #9): let the AI Mac in view hide Town Square messages. Off by default. */
@Composable
fun TrustMacRow(app: LibreApp) {
    val key by app.mesh.aiMacKey.collectAsState()
    val on by app.mesh.trustsAiMac.collectAsState()
    if (key == null) return
    Row(Modifier.fillMaxWidth().heightIn(min = 48.dp).clickable { app.run { it.setTrustAiMac(!on) } }, verticalAlignment = Alignment.CenterVertically) {
        Column(Modifier.weight(1f).padding(end = 12.dp)) {
            Text("Let the AI Mac hide Town Square messages", style = MaterialTheme.typography.titleMedium)
            Text("Turn this on only for your team's own Mac. Messages it hides are removed from Town Square on this phone.",
                style = MaterialTheme.typography.bodySmall, color = MaterialTheme.colorScheme.onSurfaceVariant)
        }
        Switch(checked = on, onCheckedChange = { v -> app.run { it.setTrustAiMac(v) } })
    }
    HorizontalDivider(Modifier.padding(vertical = 8.dp))
}

/** "Keep relaying in the background" (RelayService, issue #4). Off until the person turns it on. */
@Composable
fun BackgroundRelayRow(app: LibreApp) {
    val on by app.backgroundRelay.collectAsState()
    val power by app.power.collectAsState()
    // Android 13+: ask to show the relay's notification. The relay runs either way; without the
    // permission its notification only appears in the system's list of running apps.
    val notify = rememberLauncherForActivityResult(ActivityResultContracts.RequestPermission()) { app.setBackgroundRelay(true) }
    val ctx = LocalContext.current
    fun turnOn() {
        if (Build.VERSION.SDK_INT >= 33 && ContextCompat.checkSelfPermission(ctx, Manifest.permission.POST_NOTIFICATIONS) != PackageManager.PERMISSION_GRANTED) {
            notify.launch(Manifest.permission.POST_NOTIFICATIONS)
        } else app.setBackgroundRelay(true)
    }
    Row(Modifier.fillMaxWidth().heightIn(min = 48.dp).clickable { if (on) app.setBackgroundRelay(false) else turnOn() },
        verticalAlignment = Alignment.CenterVertically) {
        Column(Modifier.weight(1f).padding(end = 12.dp)) {
            Text("Keep relaying in the background", style = MaterialTheme.typography.titleMedium)
            Text("Libre keeps its Bluetooth links and passes messages for people nearby while the app is closed. A notification shows while it runs, with a Stop button. It scans less when Libre is closed, the screen is off, or the battery is under 20%. Battery use is not measured yet.",
                style = MaterialTheme.typography.bodySmall, color = MaterialTheme.colorScheme.onSurfaceVariant)
            Text("Bluetooth now: ${power.name}", style = MaterialTheme.typography.bodySmall, color = MaterialTheme.colorScheme.onSurfaceVariant)
        }
        Switch(checked = on, onCheckedChange = { if (it) turnOn() else app.setBackgroundRelay(false) })
    }
}
