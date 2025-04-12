#include <sourcemod>
#include <tf2c>
#include <sdktools>
#include <multicolors>

#pragma semicolon 1
#pragma newdecls required

public Plugin myinfo =
{
	name = "Classic Competitive",
	author = "Jaws",
	description = "Some tweaks to TF2 Classic to facilitate competitive play",
	version = "1.1",
	url = ""
};

//---------------------------------------------GLOBALS---------------------------------------------

bool g_ReadyAllowed = false;	// True if ready is available to players.
int g_Players = 0;				// Total voters connected. Doesn't include fake clients.
int g_Readied = 0;				// Total number of "say rtv" votes
bool g_Ready[MAXPLAYERS+1] = {false, ...};
int g_Vips[4] = {0,...};
bool g_IsVip[MAXPLAYERS+1] = {false, ...};
bool g_GameInProgress = false;
bool g_FirstRound = true;
bool g_AllowMaptimeReset;
bool g_PlayerTeam_Suppress = false;
bool g_StopwatchEnabled = false; //if stopwatch is on
bool g_StopwatchStored = false; //If stopwatch has a time stored. Records times for BLU if false, compares current BLU to stored times if true.
int g_StopwatchFirstCount = 0; //stopwatch ON: number of points capped by team attacking first
int g_StopwatchFirstTime = 9999999; //stopwatch ON: number of ticks for team attacking first to cap the last point they got
int g_StopwatchSecondCount = 0; //stopwatch ON: number of points capped by team attacking second
int g_StopwatchSecondTime = 9999999; //stopwatch ON: number of ticks for team attacking second to cap the last point they got
int g_StopwatchStartTick = 0; //stopwatch ON: tick that the current round started

Handle g_GameStartTimer = INVALID_HANDLE;
Handle g_ReadyReminderTimer = INVALID_HANDLE;
Handle g_GameConf;

Address m_bResetTeamScores;
Address m_bResetPlayerScores;
Address m_bResetRoundsPlayed;

//---------------------------------------------CONVARS---------------------------------------------

static ConVar s_ConVar_Restart;
static ConVar s_ConVar_MaptimeReset;
static ConVar s_ConVar_Stopwatch;

//---------------------------------------------BUILT-IN FUNCTIONS---------------------------------------------

public void OnPluginStart()
{
	RegConsoleCmd("sm_ready", Command_Ready);
	RegConsoleCmd("sm_unready", Command_Unready);
	RegConsoleCmd("sm_unclass", Command_Unclass);
	RegServerCmd("sm_display_unready", Command_DisplayUnreadyClients);

	s_ConVar_Restart = FindConVar("mp_restartgame");
	s_ConVar_MaptimeReset = FindConVar("tf2c_allow_maptime_reset");
	
	s_ConVar_Stopwatch = CreateConVar(
		"cc_stopwatch", "0",
		"Whether to run stopwatch during rounds.\n\t0 - False\n\t1 - True",
		_,
		true, 0.0,
		true, 1.0
	);
	s_ConVar_Stopwatch.AddChangeHook(conVarChanged_Stopwatch);
	g_StopwatchEnabled = view_as<bool>(s_ConVar_Stopwatch.IntValue);

	HookEvent("player_team", event_PlayerTeam_Pre, EventHookMode_Pre);
	HookEvent("player_changeclass", event_Player_ChangeClass_Pre, EventHookMode_Pre);
	HookEvent("teamplay_round_win", event_Round_Win_Post, EventHookMode_Post);
	HookEvent("teamplay_round_start", event_Round_Start_Post, EventHookMode_Post);
	HookEvent("teamplay_point_captured", event_Point_Captured_Post, EventHookMode_Post);
	

	g_GameConf = LoadGameConfigFile("classiccompetitive");

	OnMapEnd();

	/* Handle late load */
	for (int i=1; i<=MaxClients; i++)
	{
		if (IsClientConnected(i))
		{
			if(GetClientTeam(i) > 1)
			{
				g_Players++;
			}
		}
	}
}

public void OnMapEnd()
{
	g_GameInProgress = false;
	g_FirstRound = true;
	g_ReadyAllowed = false;
	g_Players = 0;
	g_Readied = 0;
	g_Vips = {0, 0, 0, 0};
}

static void conVarChanged_Stopwatch(ConVar convar, const char[] oldValue, const char[] newValue) {
	g_StopwatchEnabled = StringToInt(newValue) ? true : false;
}

public void OnConfigsExecuted()
{
	CreateTimer(15.0, Timer_DelayReady, _, TIMER_FLAG_NO_MAPCHANGE);
	g_AllowMaptimeReset = s_ConVar_MaptimeReset.BoolValue;
	Address pGameRules = GameConfGetAddress(g_GameConf, "GameRules");
	m_bResetTeamScores = pGameRules + view_as<Address>(593);
	m_bResetPlayerScores = pGameRules + view_as<Address>(594);
	m_bResetRoundsPlayed = pGameRules + view_as<Address>(595);
}

public void OnClientDisconnect(int client)
{
    if(!IsFakeClient(client) && GetClientTeam(client) > 1)
    {
        g_Players--;
    }

    int team = GetClientTeam(client);
    if(team > 1 && g_IsVip[client])
    {
		SetTeamVIP(team, 0);
		g_IsVip[client] = false;
    }

    if (g_Ready[client])
	{
		UnreadyClient(client);
	}
}

//---------------------------------------------HOOK FUNCTIONS---------------------------------------------

public Action event_Player_ChangeClass_Pre(Event event, const char[] name, bool dontBroadcast)
{
	int client = GetClientOfUserId(event.GetInt("userid"));
	TFClassType class = view_as<TFClassType>(event.GetInt("class"));
	TFClassType oldClass = TF2_GetPlayerClass(client);
	int team = GetClientTeam(client);
	if(class != oldClass)
	{
		if (g_Ready[client] && !g_GameInProgress)
		{
			UnreadyClient(client);
		}
	}
	if(team > 1)
	{
		if(class == TFClass_Civilian)
		{
			if (g_Vips[team-2] != 0 && g_Vips[team-2] != client)
			{
				if(!IsFakeClient(client))
				{
					char teamcolour[16];
					switch (team)
					{
						case 2:
						{
							strcopy(teamcolour, 16, "{red}");
						}
						case 3:
						{
							strcopy(teamcolour, 16, "{blue}");
						}
						case 4:
						{
							strcopy(teamcolour, 16, "{lightgreen}");
						}
						case 5:
						{
							strcopy(teamcolour, 16, "{gold}");
						}
					}
					CPrintToChat(client, "Failed to become VIP, taken by %s%N", teamcolour, g_Vips[team-2]);
				}
				if(oldClass != TFClass_Civilian)
				{
					TF2_SetPlayerClass(client, oldClass, false, true);
				}
				else
				{
					TF2_SetPlayerClass(client, TFClass_Unknown, false, true);
				}
				g_IsVip[client] = false;
				return Plugin_Handled;
			}
			g_IsVip[client] = true;
			SetTeamVIP(team, client);
			if(!IsTeamEscorting(team))
			{
				SetEntProp(client, Prop_Send, "m_iObserverMode", 5);
				TF2_SetPlayerClass(client, TFClass_Unknown, false, true);
				if (IsPlayerAlive(client))
				{
					// Hack to prevent the player from suiciding when they change teams.
					SetEntProp(client, Prop_Send, "m_lifeState", 2);
				}
				g_PlayerTeam_Suppress = true;
				ChangeClientTeam(client, 1);
				ChangeClientTeam(client, team);
				g_PlayerTeam_Suppress = false;
			}
		}
		else
		{
			if(g_IsVip[client])
			{
				SetTeamVIP(team, 0);
				g_IsVip[client] = false;
			}
		}
	}
	return Plugin_Continue;
}

public Action event_PlayerTeam_Pre(Event event, const char[] name, bool dontBroadcast) {
	if(g_PlayerTeam_Suppress)
	{
		event.SetBool("silent", true);
		return Plugin_Continue;
	}
	if(!event.GetBool("disconnect"))
	{
		int client = GetClientOfUserId(event.GetInt("userid"));
		int team = event.GetInt("team");
		int oldTeam = event.GetInt("oldteam");
		if(team != oldTeam)
		{
			bool fromSpec = (oldTeam <= 1);
			bool toSpec = (team <= 1);
			if(event.GetBool("silent"))
			{
				if(!fromSpec && g_IsVip[client])
				{
					if(!toSpec)
					{
						SetTeamVIP(team, client);
						if(IsTeamEscorting(team))
						{
							TF2_SetPlayerClass(client, TFClass_Civilian, false, true);
						}
						else
						{
							SetEntProp(client, Prop_Send, "m_iObserverMode", 5);
							TF2_SetPlayerClass(client, TFClass_Unknown, false, true);
							if (IsPlayerAlive(client))
							{
								SetEntProp(client, Prop_Send, "m_lifeState", 2);
							}
							g_PlayerTeam_Suppress = true;
							ChangeClientTeam(client, 1);
							ChangeClientTeam(client, team);
							g_PlayerTeam_Suppress = false;
						}
					}
					if(g_Vips[oldTeam - 2] == client)
					{
						SetEntProp(GetTeamEntity(oldTeam), Prop_Send, "m_iVIP", 0);
						g_Vips[oldTeam - 2] = 0;
					}
				}
			}
			else
			{
				TF2_SetPlayerClass(client, TFClass_Unknown, false, true);
				if (g_Ready[client])
				{
					UnreadyClient(client);
				}
				if(!fromSpec && g_IsVip[client])
				{
					SetTeamVIP(oldTeam, 0);
					g_IsVip[client] = false;
				}
			}
			if(!IsFakeClient(client))
			{
				if(toSpec && !fromSpec)
				{
					g_Players--;
				}
				else if (fromSpec && !toSpec)
				{
					g_Players++;
				}
			}
		}
	}

	return Plugin_Continue;
}

public Action event_Round_Start_Post(Event event, const char[] name, bool dontBroadcast)
{
	s_ConVar_MaptimeReset.BoolValue = g_AllowMaptimeReset;
	for(int i = 0; i < GetPlayTeamCount(); i++)
	{
		if(g_Vips[i] != 0)
		{
			if(IsTeamEscorting(i + 2))
			{
				TF2_SetPlayerClass(g_Vips[i], TFClass_Civilian, false, true);
				SetTeamVIP(i+2, g_Vips[i]);
			}
		}
	}
	if(g_Readied < g_Players && g_Players > 0)
	{
		g_GameInProgress = false;
		ServerCommand("mp_tournament_restart");
		if(g_FirstRound)
		{
			CPrintToChatAll("{yellow}Round will start when players are ready. {default}!ready to start");
		}
		else
		{
			CPrintToChatAll("{yellow}Game paused. Round will start when players are ready. {default}!ready to start");
		}
	}
	g_StopwatchStartTick = GetGameTickCount();
	return Plugin_Continue;
}

public Action event_Round_Win_Post(Event event, const char[] name, bool dontBroadcast)
{
	if(g_Readied == g_Players && g_Players > 0)
	{
		CPrintToChatAll("{yellow}All players ready! Continuing to next round. {default}!unready to cancel!");
	}
	g_FirstRound = false;
	
	if (g_StopwatchEnabled) {
		// TODO: if stopwatch is stored, determine winner and clear stopwatch values
			if (g_StopwatchStored) {
				CPrintToChatAll("{paleturquoise}Resetting Stopwatch.");
				if ((g_StopwatchSecondCount < g_StopwatchFirstCount) || (g_StopwatchFirstCount == g_StopwatchSecondCount && g_StopwatchSecondTime > g_StopwatchFirstTime)){
					int stopwatchSecondTimeSecs = RoundToFloor(g_StopwatchSecondTime * 0.015);
					int stopwatchFirstTimeSecs = RoundToFloor(g_StopwatchFirstTime * 0.015);
					CPrintToChatAll("{red}Team 1{paleturquoise} wins! {red}Team 1{paleturquoise} capped %i points in %i seconds {lightgrey}(%i ticks), {blue}Team 2{paleturquoise} capped %i points in %i seconds {lightgrey}(%i ticks)", g_StopwatchFirstCount, stopwatchFirstTimeSecs, g_StopwatchFirstTime, g_StopwatchSecondCount, stopwatchSecondTimeSecs, g_StopwatchSecondTime);
				}
			}
			else {
				if(g_StopwatchFirstCount == 0){
					g_StopwatchFirstTime = GetGameTickCount() - g_StopwatchStartTick;
				}
				CPrintToChatAll("{blue}Team 1{paleturquoise}'s time has been set. If {red}Team 2 {paleturquoise}captures more points or captures the same number of points faster, {red}Team 2 {paleturquoise}will win.");
			}
		//both sides of conditional swap regardless
		g_StopwatchStored = !g_StopwatchStored;
	}
	
	return Plugin_Continue;
}

public Action event_Point_Captured_Post(Event event, const char[] name, bool dontBroadcast) {
	if (g_StopwatchEnabled) {
		if (g_StopwatchStored) {
				g_StopwatchSecondCount = event.GetInt("cp") + 1;
				g_StopwatchSecondTime = GetGameTickCount() - g_StopwatchStartTick;
				int stopwatchSecondTimeSecs = RoundToFloor(g_StopwatchSecondTime * 0.015);
				int stopwatchFirstTimeSecs = RoundToFloor(g_StopwatchFirstTime * 0.015);
				CPrintToChatAll("{blue}Team 2 {paleturquoise}capped point %i in %i seconds {lightgrey}(%i ticks)", g_StopwatchSecondCount, stopwatchSecondTimeSecs, g_StopwatchSecondTime);
				if ((g_StopwatchSecondCount > g_StopwatchFirstCount) || (g_StopwatchFirstCount == g_StopwatchSecondCount && g_StopwatchSecondTime < g_StopwatchFirstTime)) {
					CPrintToChatAll("{blue}Team 2{paleturquoise} wins! {red}Team 1{paleturquoise} capped %i points in %i seconds {lightgrey}(%i ticks), {blue}Team 2{paleturquoise} capped %i points in %i seconds {lightgrey}(%i ticks)", g_StopwatchFirstCount, stopwatchFirstTimeSecs, g_StopwatchFirstTime, g_StopwatchSecondCount, stopwatchSecondTimeSecs, g_StopwatchSecondTime);

					//force a BLU win here!
				}
			}
		else {
			g_StopwatchFirstCount = event.GetInt("cp") + 1;
			g_StopwatchFirstTime = GetGameTickCount() - g_StopwatchStartTick;
			int stopwatchFirstTimeSecs = RoundToFloor(g_StopwatchFirstTime * 0.015);
			CPrintToChatAll("{blue}Team 1{paleturquoise} capped point %i in %i seconds {lightgrey}(%i ticks)", g_StopwatchFirstCount, stopwatchFirstTimeSecs, g_StopwatchFirstTime);
		}
	}
	return Plugin_Continue;
}

//---------------------------------------------COMMAND FUNCTIONS---------------------------------------------

public Action Command_Unclass(int client, int args)
{
	int team = GetClientTeam(client);
	TF2_SetPlayerClass(client, TFClass_Unknown, false, true);
	if (IsPlayerAlive(client))
	{
		// Hack to prevent the player from suiciding when they change teams.
		SetEntProp(client, Prop_Send, "m_lifeState", 2);
	}
	SetEntProp(client, Prop_Send, "m_iObserverMode", 5);
	g_PlayerTeam_Suppress = true;
	ChangeClientTeam(client, 1);
	ChangeClientTeam(client, team);
	g_PlayerTeam_Suppress = false;
	ClientCommand(client, "changeclass");

	if (g_Ready[client] && !g_GameInProgress)
	{
		UnreadyClient(client);
	}
	if(team > 1 && g_IsVip[client])
	{
		SetTeamVIP(team, 0);
		g_IsVip[client] = false;
	}

	return Plugin_Handled;
}

public Action Command_Ready(int client, int args)
{
	if (!client)
	{
		return Plugin_Handled;
	}

	if (!g_ReadyAllowed)
	{
		ReplyToCommand(client, "[SM] Command not available at this time");
		return Plugin_Handled;
	}

	if(GetClientTeam(client) <= 1)
	{
		ReplyToCommand(client, "[SM] Only players on teams can ready up");
		return Plugin_Handled;
	}

	if (g_Ready[client])
	{
		CReplyToCommand(client, "[SM] Already readied up! {lightgrey}[%i/%i] (use 'unready' to undo)", g_Readied, g_Players);
		return Plugin_Handled;
	}

	ReadyClient(client);

	return Plugin_Handled;
}

public Action Command_Unready(int client, int args)
{
	if (!client)
	{
		return Plugin_Handled;
	}

	if (!g_ReadyAllowed)
	{
		ReplyToCommand(client, "[SM] Command not available at this time");
		return Plugin_Handled;
	}

	if(GetClientTeam(client) <= 1)
	{
		ReplyToCommand(client, "[SM] Only players on teams can ready up");
		return Plugin_Handled;
	}

	if (!g_Ready[client])
	{
		ReplyToCommand(client, "[SM] You haven't readied up yet");
		return Plugin_Handled;
	}

	UnreadyClient(client);

	return Plugin_Handled;
}

public Action Command_DisplayUnreadyClients(int args)
{
	DisplayUnreadyClients();
	return Plugin_Handled;
}

//---------------------------------------------TIMER FUNCTIONS-------------------------------------------------------

public Action Timer_StartGame(Handle timer)
{
	g_GameStartTimer = INVALID_HANDLE;
	if(g_FirstRound)
	{
		RestartGame();
	}
	else
	{
		ContinueGame();
	}
	return Plugin_Continue;
}

public Action Timer_DelayReady(Handle timer)
{
	g_ReadyAllowed = true;

	return Plugin_Continue;
}

public Action Timer_ReadyReminder(Handle timer)
{
	g_ReadyReminderTimer = INVALID_HANDLE;
	DisplayUnreadyClients();
	return Plugin_Continue;
}

//---------------------------------------------PLUGIN FUNCTIONS---------------------------------------------

/**
 * @return true if the game is in the setup phase.
 */
bool IsInSetup() {
	return GameRules_GetProp("m_bInSetup") ? true : false;
}

/**
 * @return the number of playable teams.
 */
int GetPlayTeamCount() {
	return GameRules_GetProp("m_bFourTeamMode") ? 4 : 2;
}

/**
* Check if the given team is escorting a VIP.
*
* @param team    Index of the team to check.
* @return        true if the team is escorting a VIP.
*/
bool IsTeamEscorting(int team) {
	return GetEntProp(GetTeamEntity(team), Prop_Send, "m_bEscorting") ? true : false;
}

void SetTeamVIP(int team, int client) {
	SetEntProp(GetTeamEntity(team), Prop_Send, "m_iVIP", client);
	if(client == g_Vips[team-2])
	{
		return;
	}
	g_Vips[team-2] = client;
	if(client == 0)
	{
		switch(team)
		{
			case 2:
			{
				CPrintToChatAll("Team {red}RED {default}no longer have a VIP");
			}
			case 3:
			{
				CPrintToChatAll("Team {blue}BLU {default}no longer have a VIP");
			}
			case 4:
			{
				CPrintToChatAll("Team {lightgreen}GRN {default}no longer have a VIP");
			}
			case 5:
			{
				CPrintToChatAll("Team {gold}YLW {default}no longer have a VIP");
			}
		}
		return;
	}
	Event eventVipChange = CreateEvent("vip_assigned");
	eventVipChange.SetInt("userid", GetClientUserId(client));
	eventVipChange.SetInt("team", team);
	eventVipChange.Fire();
}

/**
 * Gets the VIP of the given team.
 *
 * @param team    Index of the team to get the VIP of.
 * @return        Client index of the team's VIP or 0 if none.
 */
int GetTeamVIP(int team) {
	return GetEntProp(GetTeamEntity(team), Prop_Send, "m_iVIP");
}

void ReadyClient(int client)
{
	g_Readied++;
	g_Ready[client] = true;

	char teamcolour[16];
	int team = GetClientTeam(client);
	switch (team)
	{
		case 2:
		{
			strcopy(teamcolour, 16, "{red}");
		}
		case 3:
		{
			strcopy(teamcolour, 16, "{blue}");
		}
		case 4:
		{
			strcopy(teamcolour, 16, "{lightgreen}");
		}
		case 5:
		{
			strcopy(teamcolour, 16, "{gold}");
		}
	}

	CPrintToChatAll("%s%N {default}is ready to go! {lightgrey}[%i/%i]", teamcolour, client, g_Readied, g_Players);
	AttemptStartGame();
}

void UnreadyClient(int client)
{
	g_Readied--;
	g_Ready[client] = false;

	char teamcolour[16];
	int team = GetClientTeam(client);
	switch (team)
	{
		case 2:
		{
			strcopy(teamcolour, 16, "{red}");
		}
		case 3:
		{
			strcopy(teamcolour, 16, "{blue}");
		}
		case 4:
		{
			strcopy(teamcolour, 16, "{lightgreen}");
		}
		case 5:
		{
			strcopy(teamcolour, 16, "{gold}");
		}
	}

	CPrintToChatAll("%s%N {default}is no longer ready {lightgrey}[%i/%i]", teamcolour, client, g_Readied, g_Players);
	CancelStartGame();
}

void DisplayUnreadyClients()
{
	int unready = g_Players - g_Readied;
	if(unready == 0)
	{
		return;
	}
	char prefix[32];
	char playernames[1024];
	int len_playernames = 0;
	char suffix[32];
	Format(prefix, 32, "%i players not ready:", unready);
	for(int i = 1; i < MaxClients; i++)
	{
		if(IsClientInGame(i) && !g_Ready[i] && GetClientTeam(i) > 1 && !IsFakeClient(i))
		{
			char name[MAX_NAME_LENGTH];
			GetClientName(i, name, MAX_NAME_LENGTH);
			if(strlen(name) + 2 < 128 - len_playernames)
			{
				if(len_playernames != 0)
				{
					StrCat(playernames, 1024, "{default}, ");
					len_playernames += 2;
				}
				int team = GetClientTeam(i);
				switch (team)
				{
					case 2:
					{
						StrCat(playernames, 1024, "{red}");
					}
					case 3:
					{
						StrCat(playernames, 1024, "{blue}");
					}
					case 4:
					{
						StrCat(playernames, 1024, "{lightgreen}");
					}
					case 5:
					{
						StrCat(playernames, 1024, "{gold}");
					}
				}
				StrCat(playernames, 1024, name);
				unready -= 1;
				len_playernames += strlen(name);
			}
		}
	}
	if(unready > 0)
	{
		Format(suffix, 32, "+ %i others", unready);
	}
	CPrintToChatAll("%s %s %s", prefix, playernames, suffix);
}

bool AttemptStartGame()
{
	if(g_ReadyReminderTimer != INVALID_HANDLE)
	{
		delete g_ReadyReminderTimer;
	}
	if(g_GameInProgress)
	{
		return false;
	}
	if (g_Readied < g_Players || g_Players <= 0)
	{
		g_ReadyReminderTimer = CreateTimer(5.0, Timer_ReadyReminder, _, TIMER_FLAG_NO_MAPCHANGE);
		return false;
	}
	for(int i = 0; i < GetPlayTeamCount();i++)
	{
		if(IsTeamEscorting(i + 2))
		{
			if(GetTeamVIP(i + 2) == 0)
			{
				CPrintToChatAll("{yellow}All players ready but a team is missing a VIP.");
				return false;
			}
		}
	}
	CPrintToChatAll("{yellow}All players ready! Starting the round in 5 seconds. {default}!unready to cancel");
	g_GameStartTimer = CreateTimer(5.0, Timer_StartGame, _, TIMER_FLAG_NO_MAPCHANGE);
	g_GameInProgress = true;
	return true;
}

void CancelStartGame()
{
	if(g_GameInProgress)
	{
		if(g_GameStartTimer != INVALID_HANDLE)
		{
			delete g_GameStartTimer;
			CPrintToChatAll("{yellow}Round start cancelled");
			g_GameInProgress = false;
		}
		else if(IsInSetup())
		{
			CPrintToChatAll("{yellow}Round start cancelled during setup");
			ServerCommand("mp_tournament_restart");
			g_GameInProgress = false;
		}
		else
		{
			CPrintToChatAll("{yellow}Game will pause after this round");
		}
	}
}

void ContinueGame()
{
	s_ConVar_Restart.IntValue = 1;
	s_ConVar_MaptimeReset.BoolValue = false;
	StoreToAddress(m_bResetPlayerScores, 0, NumberType_Int8);
	StoreToAddress(m_bResetRoundsPlayed, 0, NumberType_Int8);
	StoreToAddress(m_bResetTeamScores, 0, NumberType_Int8);
}

void RestartGame()
{
	s_ConVar_Restart.IntValue = 1;
}
