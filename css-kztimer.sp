#include <morecolors>
#include <sourcemod>
#include <smlib>
#include <sdkhooks>
#include <clientprefs>

#define MAX_TIMES 8192

public Plugin myinfo = {
  name = "KZTimer",
  author = "networkheaven.net",
  description = "KZTimer",
  version = "420.69",
  url = "networkheaven.net"
};

enum MapZoneType { 
  ZONE_NONE,
  ZONE_BUTTON,
  ZONE_TRIGGER,
};

enum struct PlayerData {
  bool bIsInRun;
  bool bIsInZone;

  float fStartTime;
  float fEndTime;
  float fPausedTime;

  int nJumps;
  int nTeleports;

  bool bShowingMenu;
  bool bShowViewmodel;

  float vStartPoint[3];
  float vStartAngle[3];

  float vPausedAngle[3];
  float vLastAngle[3];

  float vSavedPoint[3];
  float vSavedAngles[3];
  bool  bSavedDuck;
  bool  bSavedPoint;
  bool  bPausedRun;

  int nDuckTicks;
}

enum struct TimeData {
  float fFinalTime;
  int nJumps;
  int nTeleports;
  char sName[64];
  char sSteamid[32];
  char sMapName[32];
  int nTimestamp;
  int nPosition;
}

public bool       g_isKZ;
public PlayerData g_playerData[MAXPLAYERS + 1];
public Handle     g_DB = INVALID_HANDLE;

public int        g_topTime = 0;
public TimeData   g_times[MAX_TIMES];
public Cookie     g_hideWeaponCookie;

public ConVar g_nhWarmup = null;

public void OnPluginStart() {
  HookEntityOutput( "func_button", "OnPressed", OnButtonUsed );

  RegConsoleCmd( "sm_savepoint", Command_SavePoint, "Save your current position." );
  RegConsoleCmd( "sm_loadpoint", Command_LoadPoint, "Load your saved position." );
  RegConsoleCmd( "sm_tpmenu", Command_CheckpointPanel, "Show the checkpoint menu." );
  RegConsoleCmd( "sm_tp", Command_CheckpointPanel, "Show the checkpoint menu." );
  RegConsoleCmd( "sm_pause", Command_PauseRun, "Pause/resume your run." );
  RegConsoleCmd( "sm_restart", Command_Restart, "Restart your run." );
  RegConsoleCmd( "sm_maptop", Command_Maptop, "Show the top 50 times." );
  RegConsoleCmd( "sm_m", Command_Maptop, "Show the top 50 times." );
  RegConsoleCmd( "sm_mrank", Command_MyRank, "Show your rank on the current map." );
  RegConsoleCmd( "sm_viewmodel", Command_HideViewmodel, "Toggle viewmodel." );
  RegConsoleCmd( "sm_vm", Command_HideViewmodel, "Toggle viewmodel." ); 
  RegConsoleCmd( "sm_hideweapon", Command_HideViewmodel, "Toggle viewmodel." );
  RegConsoleCmd( "sm_noclip", Command_Noclip, "Toggle noclip." );

  HookEvent( "player_spawn", Event_PlayerSpawn, EventHookMode_Post );
  HookEvent( "player_jump", Event_PlayerJump, EventHookMode_Post );

  g_hideWeaponCookie = RegClientCookie( "kztimer_hideweapon", "kztimer_hideweapon", CookieAccess_Public );
}

public void OnPluginEnd() {
}

public void OnAllPluginsLoaded() {

}

public void ClearPlayerData( int i ) {
  g_playerData[i].bIsInRun = false;
  g_playerData[i].bIsInZone = false;
  g_playerData[i].fStartTime = 0.0;
  g_playerData[i].fEndTime = 0.0;
  g_playerData[i].fPausedTime = 0.0;
  g_playerData[i].nJumps = 0;
  g_playerData[i].nTeleports = 0;
  g_playerData[i].bSavedPoint = false;
  g_playerData[i].bPausedRun = false;
  g_playerData[i].bShowingMenu = false;
  g_playerData[i].nDuckTicks = 0;
  g_playerData[i].bShowViewmodel = true;
}

public void ClearAllPlayers() {
  for( int i = 0; i < MAXPLAYERS; i++ ) {
    ClearPlayerData( i );
  }
}

public void OnClientPutInServer( int client ) {
  ClearPlayerData( client );

  SDKHook( client, SDKHook_OnTakeDamage, OnTakeDamage );
}

public void CreateDatabaseCallback( Handle owner, DBResultSet hndl, const char[] error, any pack ) {
  if( hndl == INVALID_HANDLE ) {
    LogError( "Failed to create database: %s", error );
    return;
  } 

  char mapName[256];
  GetCurrentMap( mapName, sizeof(mapName) );

  LoadDatabase();
}

public void CreateDatabase() {
  if( g_DB != INVALID_HANDLE ) {
    CloseHandle( g_DB );
  }

  char error[256];
  g_DB = SQL_Connect( "kztimer", true, error, sizeof(error) );

  if( g_DB == INVALID_HANDLE ) {
    LogError( "Failed to connect to database: %s", error );
    return;
  }

  SQL_TQuery( g_DB, CreateDatabaseCallback, "CREATE TABLE IF NOT EXISTS times ( id INTEGER NOT NULL PRIMARY KEY AUTOINCREMENT, steamid VARCHAR(32) NOT NULL , name VARCHAR(64) NOT NULL , map VARCHAR(32) NOT NULL , time FLOAT NOT NULL , jumps INT NOT NULL , teleports INT NOT NULL , date TIMESTAMP NOT NULL DEFAULT CURRENT_TIMESTAMP )" );
}

public void LoadDatabaseCallback( Handle owner, DBResultSet hndl, const char[] error, any pack ) {
  if( hndl == INVALID_HANDLE ) {
    LogError( "Failed to load database: %s", error );
    return;
  } 

  g_topTime = SQL_GetRowCount( hndl );
  LogMessage( "Loaded %d times", g_topTime );
  for( int i = 0; i < g_topTime; i++ ) {
    SQL_FetchRow( hndl );
    TimeData data;

    data.fFinalTime = SQL_FetchFloatByName( hndl, "time" );
    data.nJumps = SQL_FetchIntByName( hndl, "jumps" );
    data.nTeleports = SQL_FetchIntByName( hndl, "teleports" );
    data.nTimestamp = SQL_FetchIntByName( hndl, "date" );
    SQL_FetchStringByName( hndl, "name", data.sName, sizeof(data.sName) );
    SQL_FetchStringByName( hndl, "steamid", data.sSteamid, sizeof(data.sSteamid) );
    SQL_FetchStringByName( hndl, "map", data.sMapName, sizeof(data.sMapName) );

    data.nPosition = i;

    g_times[i] = data;
  }
}

public void LoadDatabase() {
  char mapName[256];
  GetCurrentMap( mapName, sizeof(mapName) );

  char query[1024];
  Format( query, sizeof(query), "SELECT * FROM times WHERE map = '%s' ORDER BY time ASC", mapName );
  SQL_TQuery( g_DB, LoadDatabaseCallback, query );
}

public UpdateTimeCallback( Handle owner, DBResultSet hndl, const char[] error, TimeData pack ) {
  if( hndl == INVALID_HANDLE ) {
    LogError( "Failed to update time: %s", error );
    return;
  } 

  SaveTime( pack );
}

public UpdateTime( TimeData data ) {
  char query[1024];
  Format( query, sizeof(query), "DELETE FROM times WHERE steamid = '%s' AND map = '%s'", data.sSteamid, data.sMapName );
  DBResultSet hndl = SQL_Query( g_DB, query );

  if( hndl == INVALID_HANDLE ) {
    char err[255];
    SQL_GetError( g_DB, err, sizeof(err) );
    LogError( "Failed to update time: %s", err );
    return;
  }

  SaveTime( data );
}

public void SaveTimeCallback( Handle owner, DBResultSet hndl, const char[] error, any pack ) {
  if( hndl == INVALID_HANDLE ) {
    LogError( "Failed to save time: %s", error );
    return;
  } 

  LoadDatabase();
}

public void SaveTime( TimeData data ) {
  float time = data.fFinalTime;
  int jumps = data.nJumps;
  int teleports = data.nTeleports;

  char query[1024];
  Format( query, sizeof(query), "INSERT INTO times ( steamid, name, map, time, jumps, teleports ) VALUES ( '%s', '%s', '%s', '%f', '%d', '%d' )", data.sSteamid, data.sName, data.sMapName, time, jumps, teleports );
  SQL_TQuery( g_DB, SaveTimeCallback, query );
}

public void ClearRecords() {
  for( int i = 0; i < MAX_TIMES; i++ ) {
    g_times[i].fFinalTime = 0.0;
    g_times[i].nJumps = 0;
    g_times[i].nTeleports = 0;
    g_times[i].nTimestamp = 0;
    g_times[i].nPosition = 0;
    g_times[i].sName[0] = '\0';
    g_times[i].sSteamid[0] = '\0';
    g_times[i].sMapName[0] = '\0';
  }
}

public Action CommandTimer( Handle timer, any unused ) {
  ServerCommand( "bot_kick; bot_quota 0; nh_warmup 0; sv_airaccelerate 12; mp_falldamage 0; sv_enablebunnyhopping 1; mp_ignore_round_win_conditions 1" );
  if( !g_nhWarmup )
    g_nhWarmup = FindConVar( "nh_warmup" );
  else
    SetConVarInt( g_nhWarmup, 0 );

  return Plugin_Handled;
}

public void OnMapStart() {
  ClearRecords();
  char mapName[32];
  GetCurrentMap(mapName, sizeof(mapName));

  if( !strncmp( mapName, "kz_", 3, false ) 
   || !strncmp( mapName, "xc_", 3, false ) 
   || !strncmp( mapName, "bhop_", 5, false )
   || !strncmp( mapName, "bkz_", 4, false ) ) {
    g_isKZ = true;
  } else {
    g_isKZ = false;
  }

  ClearAllPlayers();

  if( g_isKZ ) {
    CreateTimer( 2.0, CommandTimer, 0, TIMER_FLAG_NO_MAPCHANGE );
    CreateDatabase();
  }

  PrecacheSound( "quake/standard/wickedsick.wav" );
}

public void OnMapEnd() {
  g_isKZ = false;
}

public void StartRun( int client ) {
  MoveType mv = GetEntityMoveType( client );
  if( mv == MOVETYPE_NOCLIP ) {
    EmitSoundToClient( client, "buttons/button10.wav" );
    CPrintToChat( client, "[{green}kz{default}] {red}You cannot use noclip during a run." );

    return;
  }

  EmitSoundToClient( client, "buttons/button17.wav" );
  CPrintToChat( client, "[{green}kz{default}] {white}run started." );
  g_playerData[client].bIsInRun = true;
  g_playerData[client].fStartTime = GetGameTime();

  g_playerData[client].nJumps = 0;
  g_playerData[client].nTeleports = 0;

  float origin[3];
  GetClientAbsOrigin( client, origin );
  Array_Copy( origin, g_playerData[client].vStartPoint, 3 );

  float angles[3];
  GetClientAbsAngles( client, angles );
  Array_Copy( angles, g_playerData[client].vStartAngle, 3 );

  g_playerData[client].bSavedPoint = false;
  g_playerData[client].bPausedRun = false;

  if( g_playerData[client].bShowingMenu ) {
    ShowCheckpointMenu( client, true );
  }
}

public void EndRun( int client ) {
  if( !g_playerData[client].bIsInRun ) 
    return;

  EmitSoundToClient( client, "buttons/button9.wav" );
  g_playerData[client].bIsInRun = false;
  g_playerData[client].fEndTime = GetGameTime();

  float time = GetGameTime() - g_playerData[client].fStartTime;
  int hours = RoundToFloor( time ) / 3600;
  int minutes = RoundToFloor( time ) / 60;
  int seconds = RoundToFloor( time ) - hours * 3600 - minutes * 60;
  int milliseconds = RoundToFloor( (time - RoundToFloor( time )) * 1000 );

  char name[64];
  GetClientName( client, name, sizeof(name) );

  char color[16];
  strcopy( color, sizeof(color), g_playerData[client].nTeleports > 0 ? "{unique}" : "{cyan}" );

  char chatStr[256];
  Format( chatStr, sizeof(chatStr), "[{green}kz{default}] {violet}%s {white}finished the map", name );

  float prevRunTime = -1.0;
  int runPos = -1;
  char clientSteamId[32];
  GetClientAuthId( client, AuthId_Engine, clientSteamId, sizeof(clientSteamId) );
  for( int i = 0; i < g_topTime; i++ ) {
    if( prevRunTime < 0 && !strcmp( clientSteamId, g_times[i].sSteamid ) ) {
      prevRunTime = g_times[i].fFinalTime;
    }

    if( runPos == -1 && time < g_times[i].fFinalTime ) {
      runPos = i;
    }

    if( runPos >= 0 && prevRunTime > 0 )
      break;
  }

  if( prevRunTime < 0.0 )
    Format( chatStr, sizeof(chatStr), "%s for the first time", chatStr );
  Format( chatStr, sizeof(chatStr), "%s in %s", chatStr, color );

  if( hours > 0 ) {
    Format( chatStr, sizeof(chatStr), "%s%d:%02d:%02d.%03d", chatStr, hours, minutes, seconds, milliseconds );
  } else {
    Format( chatStr, sizeof(chatStr), "%s%d:%02d.%03d", chatStr, minutes, seconds, milliseconds );
  }
  
  if( prevRunTime > 0.0 ) {
    float diff = prevRunTime - time;
    float absDiff = FloatAbs( diff );
    int diffHours = RoundToFloor( absDiff / 3600.0 );
    int diffMinutes = RoundToFloor( absDiff / 60.0 ) ;
    int diffSeconds = RoundToFloor( absDiff - ( diffMinutes * 60.0 ) ) ;
    int diffMilliseconds = RoundToFloor( ( absDiff - RoundToFloor( absDiff ) ) * 1000.0 );

    if( diffHours > 0 ) {
      Format( chatStr, sizeof(chatStr), "%s {white}[%s%s%d:%02d:%02d.%03d{white}]", chatStr, diff < 0 ? "{red}" : "{green}", diff < 0 ? "+" : "-", diffHours, diffMinutes, diffSeconds, diffMilliseconds );
    } else {
      Format( chatStr, sizeof(chatStr), "%s {white}[%s%s%d:%02d.%03d{white}]", chatStr, diff < 0 ? "{red}" : "{green}", diff < 0 ? "+" : "-", diffMinutes, diffSeconds, diffMilliseconds );
    }
  }

  if( runPos >= 0 ) {
    Format( chatStr, sizeof(chatStr), "%s {white}(#%d/%d).", chatStr, runPos + 1, g_topTime );
  } else {
    Format( chatStr, sizeof(chatStr), 
      "%s {white}(#%d/%d).", 
      chatStr, 
      g_topTime + 1, 
      prevRunTime > 0.0 ? g_topTime : g_topTime + 1 
    );
  }

  CPrintToChatAll( chatStr );

  if( prevRunTime < 0.0 || time < prevRunTime ) {
    TimeData data;
    data.fFinalTime = time;
    data.nJumps = g_playerData[client].nJumps;
    data.nTeleports = g_playerData[client].nTeleports;
    data.nTimestamp = 0;
    data.nPosition = 0;
    strcopy( data.sName, sizeof(data.sName), name );
    strcopy( data.sSteamid, sizeof(data.sSteamid), clientSteamId );
    GetCurrentMap( data.sMapName, sizeof(data.sMapName) );

    UpdateTime( data );

    if( runPos == 0 || g_topTime == 0 ) {
      CPrintToChatAll( "[{green}kz{default}] {violet}%s {white}set a new map record!", name );
      EmitSoundToAll( "quake/standard/wickedsick.wav" );
    }
  }

  g_playerData[client].fStartTime = 0.0;
  if( g_playerData[client].bShowingMenu )
    ShowCheckpointMenu( client, true );
}

public void OnButtonUsed( const char[] output, int caller, int activator, float delay ) {
  if( !g_isKZ ) return;

  char entityName[64];
  GetEntPropString( caller, Prop_Data, "m_iName", entityName, sizeof(entityName) );

  if( activator && !strcmp( entityName, "climb_startbutton" ) ) {
    StartRun( activator );
  }
  else if( activator && !strcmp( entityName, "climb_endbutton" ) ) {
    EndRun( activator ); 
  }
}

public bool AreAllPlayersOnOneTeam() {
  int ctCount = 0;
  int tCount = 0;
  for( int i = 1; i < MaxClients; ++i ) {
    if( !IsClientConnected( i ) || !IsClientInGame( i ) ) 
      continue;

    int team = GetClientTeam( i );
    if( team == 2 ) {
      if( ctCount > 0 )
        return false;
      ++tCount;
    } else if( team == 3 ) {
      if( tCount > 0 )
        return false;
      ++ctCount;
    }
  }

  return true;
}

public bool CanUseTPMenu() {
  if( g_isKZ )
    return true;

  if( g_nhWarmup == null )
    g_nhWarmup = FindConVar( "nh_warmup" );

  if( g_nhWarmup != INVALID_HANDLE && GetConVarInt( g_nhWarmup ) != 0 )
    return true;

  if( AreAllPlayersOnOneTeam() )
    return true;

  return false;
}

public void ShowCheckpointMenu( int client, bool kz ) {
  Menu menu = CreateMenu( CheckpointMenuHandler, MenuAction_Start );
  AddMenuItem( menu, "save position", "save checkpoint" );
  char buf[64];
  if( g_playerData[client].bIsInRun )
    Format( buf, sizeof(buf), "load checkpoint (%d)", g_playerData[client].nTeleports );
  else
    Format( buf, sizeof(buf), "load checkpoint" );

  AddMenuItem( menu, "load position", buf, g_playerData[client].bSavedPoint ? 0 : ITEMDRAW_DISABLED );
  
  if( kz ) {
    if( !g_playerData[client].bPausedRun )
      AddMenuItem( menu, "pause timer", "pause", g_playerData[client].bIsInRun ? 0 : ITEMDRAW_DISABLED );
    else
      AddMenuItem( menu, "resume timer", "resume", g_playerData[client].bIsInRun ? 0 : ITEMDRAW_DISABLED );

    AddMenuItem( menu, "respawn", "restart" );
  }

  DisplayMenu( menu, client, MENU_TIME_FOREVER );
  g_playerData[client].bShowingMenu = true;
}

public int CheckpointMenuHandler( Menu menu, MenuAction ma, int client, int nItem ) {
  if( client <= 0 || client > MAXPLAYERS ) return 0;

  if( ma == MenuAction_Select ) {
    switch( nItem ) {
      case 0: { Command_SavePoint( client, 0 ); }
      case 1: { Command_LoadPoint( client, 0 ); }
      case 2: { Command_PauseRun( client, 0 ); }
      case 3: { Command_Restart( client, 0 ); }
    }

    ShowCheckpointMenu( client, g_isKZ );
    return 0;
  }
  else if( ma == MenuAction_Cancel && nItem == -3 ) {
    g_playerData[client].bShowingMenu = false;
    return 0;  
  }
  else if( ma == MenuAction_End ) {
    delete menu;
  }

  return 0;
}

public Action Command_SavePoint( int client, int nargs ) {
  if( !IsPlayerAlive( client ) ) {
    CPrintToChat( client, "[{green}kz{default}] {red}You must be alive to use this command." );
    return Plugin_Handled;
  }

  if( g_nhWarmup == null ) { 
    g_nhWarmup = FindConVar( "nh_warmup" );
  }

  if( !CanUseTPMenu() ) {
    CPrintToChat( client, "[{green}kz{default}] {red}This command can only be used on KZ maps or during warmup." );
    return Plugin_Handled;
  }

  int flags = GetEntProp( client, Prop_Send, "m_fFlags" );
  if( !( flags & FL_ONGROUND) ) {
    CPrintToChat( client, "[{green}kz{default}] {red}Cannot set a checkpoint mid-air." );
    EmitSoundToClient( client, "buttons/button10.wav" );
    return Plugin_Handled;
  }

  float origin[3];
  GetClientAbsOrigin( client, origin );
  Array_Copy( origin, g_playerData[client].vSavedPoint, 3 );
  Array_Copy( g_playerData[client].vLastAngle, g_playerData[client].vSavedAngles, 3 );

  g_playerData[client].bSavedDuck = !!GetEntProp( client, Prop_Send, "m_bDucked" );
  g_playerData[client].bSavedPoint = true;

  return Plugin_Handled;
}

public Action Command_LoadPoint( int client, int nargs ) {
  if( !IsPlayerAlive( client ) ) {
    CPrintToChat( client, "[{green}kz{default}] {red}You must be alive to use this command." );
    return Plugin_Handled;
  }

  if( !g_playerData[client].bSavedPoint ) {
    CPrintToChat( client, "[{green}kz{default}] {red}You must save your position first." );
    return Plugin_Handled;
  }

  if( g_playerData[client].bPausedRun ) {
    CPrintToChat( client, "[{green}kz{default}] {red}Cannot load position while the run is paused." );
    EmitSoundToClient( client, "buttons/button10.wav" );
    return Plugin_Handled;
  }

  if( !CanUseTPMenu() ) {
    CPrintToChat( client, "[{green}kz{default}] {red}This command can only be used on KZ maps or during warmup." );
    return Plugin_Handled;
  }

  float vDiff[3], dist;
  if( !g_isKZ ) {
    for( int i = 1; i < MaxClients; ++i ) {
      if( i == client ) 
        continue;
      if( !IsClientConnected( i ) || !IsClientInGame( i ) || !IsPlayerAlive( i ) ) 
        continue;

      float origin[3];
      GetClientAbsOrigin( i, origin );

      vDiff[0] = origin[0] - g_playerData[client].vSavedPoint[0];
      vDiff[1] = origin[1] - g_playerData[client].vSavedPoint[1];

      dist = SquareRoot( vDiff[0] * vDiff[0] + vDiff[1] * vDiff[1] );
      if( FloatAbs( g_playerData[client].vSavedPoint[2] - origin[2] ) < 64.0 && dist < 64.0 ) {
        CPrintToChat( client, "[{green}kz{default}] {red}Cannot load your position because another player is standing there." );
        return Plugin_Handled;
      }
    }
  }

  float origin[3];
  Array_Copy( g_playerData[client].vSavedPoint, origin, 3 );

  float angles[3];
  Array_Copy( g_playerData[client].vSavedAngles, angles, 3 );

  float velocity[3];
  velocity[0] = 0.0;
  velocity[1] = 0.0;
  velocity[2] = -1.0;

  TeleportEntity( client, origin, angles, velocity );
  if( g_playerData[client].bSavedDuck ) {
    SetEntProp( client, Prop_Send, "m_bDucked", 1 );
    g_playerData[client].nDuckTicks = 5;
  } else {
    SetEntProp( client, Prop_Send, "m_bDucked", 0 );
  }

  if( g_playerData[client].bIsInRun ) {
    g_playerData[client].nTeleports++;
  }
  return Plugin_Handled;
}

public Action Command_PauseRun( int client, int nargs ) {
  if( !g_isKZ ) return Plugin_Handled;

  if( !g_playerData[client].bIsInRun ) {
    CPrintToChat( client, "[{green}kz{default}] {red}You must be in a run to use this command." );
    return Plugin_Handled;
  }

  if( !IsPlayerAlive( client ) ) {
    CPrintToChat( client, "[{green}kz{default}] {red}You must be alive to use this command." );
    return Plugin_Handled;
  }

  int flags = GetEntProp( client, Prop_Send, "m_fFlags" );
  if( !( flags & FL_ONGROUND) ) {
    CPrintToChat( client, "[{green}kz{default}] {red}Cannot pause mid-air." );
    EmitSoundToClient( client, "buttons/button10.wav" );

    return Plugin_Handled;
  }

  if( !g_playerData[client].bPausedRun ) {
    float runTime = GetGameTime() - g_playerData[client].fStartTime;
    g_playerData[client].fPausedTime = runTime;

    Array_Copy( g_playerData[client].vLastAngle, g_playerData[client].vPausedAngle, 3 );

    g_playerData[client].bPausedRun = true;
    CPrintToChat( client, "[{green}kz{default}] {white}run paused." );
  } else {
    g_playerData[client].fStartTime = GetGameTime() - g_playerData[client].fPausedTime;
    g_playerData[client].bPausedRun = false;

    SetEntityFlags( client, GetEntityFlags( client ) & ~FL_FROZEN );

    CPrintToChat( client, "[{green}kz{default}] {white}run resumed." );
  }

  return Plugin_Handled;
}

public Action Command_CheckpointPanel( int client, int nargs ) {
  if( !IsPlayerAlive( client ) ) {
    CPrintToChat( client, "[{green}kz{default}] {red}You must be alive to use this command." );
    return Plugin_Handled;
  }


  if( !CanUseTPMenu() ) {
    CPrintToChat( client, "[{green}kz{default}] {red}This command can only be used on KZ maps or during warmup." );
    return Plugin_Handled;
  }

  ShowCheckpointMenu( client, g_isKZ );

  return Plugin_Handled;
}

public Action Command_Restart( int client, int args ) {
  float origin[3];
  Array_Copy( g_playerData[client].vStartPoint, origin, 3 );

  float angle[3];
  Array_Copy( g_playerData[client].vStartAngle, angle, 3 );

  float velocity[3];
  velocity[0] = 0.0;
  velocity[1] = 0.0;
  velocity[2] = -1.0;

  TeleportEntity( client, origin, angle, velocity );
  return Plugin_Handled;
}

public void GetTimeString( int client, char[] buffer, int size ) {
  float time = 0.0;
  if( g_playerData[client].bPausedRun ) {
    time = g_playerData[client].fPausedTime;
  } else {
    time = GetGameTime() - g_playerData[client].fStartTime;
  }

  int hours = RoundToFloor( time ) / 3600;
  int minutes = RoundToFloor( time ) / 60;
  int seconds = RoundToFloor( time ) - hours * 3600 - minutes * 60;
  int milliseconds = RoundToFloor( (time - RoundToFloor( time )) * 1000 );

  Format( buffer, size, "time: " );

  if( hours > 0 ) {
    Format( buffer, size, "%s%d:%02d:%02d.%03d", buffer, hours, minutes, seconds, milliseconds );
  } else {
    Format( buffer, size, "%s%d:%02d.%03d", buffer, minutes, seconds, milliseconds );
  }

  Format( buffer, size, "%s\njumps: %d\nteleports: %d", buffer, g_playerData[client].nJumps, g_playerData[client].nTeleports );
  if( g_playerData[client].bPausedRun ) {
    Format( buffer, size, "%s\n[PAUSED]", buffer );
  }
}

public Action OnPlayerRunCmd(int client, int& buttons, int& impulse, float vel[3], float angles[3], int& weapon, int& subtype, int& cmdnum, int& tickcount, int& seed, int mouse[2]) {
  Array_Copy( angles, g_playerData[client].vLastAngle, 3 );
  if( !g_isKZ ) return Plugin_Continue; 

  if( !IsPlayerAlive( client ) ) {
    g_playerData[client].bIsInRun = false;
    return Plugin_Continue;
  }

  if( g_playerData[client].nDuckTicks > 0 ) {
    buttons |= IN_DUCK;
    g_playerData[client].nDuckTicks--;
  }

  SetEntityRenderMode( client, RENDER_TRANSCOLOR );
  SetEntityRenderColor( client, 255, 255, 255, 100 );

  if( GetEntityMoveType( client ) == MOVETYPE_NOCLIP && g_playerData[client].bIsInRun ) {
    g_playerData[client].bIsInRun = false;
    CPrintToChat( client, "[{green}kz{default}] {red}You cannot use noclip during a run." );
    EmitSoundToClient( client, "buttons/button10.wav" );
    return Plugin_Continue;
  }

  if( g_playerData[client].bIsInRun ) {
    char timeString[256];
    GetTimeString( client, timeString, sizeof(timeString) );
    PrintHintText( client, timeString );

    if( g_playerData[client].bPausedRun ) { 
      SetEntityFlags( client, GetEntityFlags( client ) | FL_FROZEN );
      TeleportEntity( client, NULL_VECTOR, g_playerData[client].vPausedAngle, NULL_VECTOR );
      return Plugin_Handled;
    }
  }
  
  return Plugin_Continue;
}

public Action Event_PlayerJump( Event e, const char[] name, bool dontBroadcast ) {
  int client = GetClientOfUserId( e.GetInt( "userid" ) );
  if( !g_isKZ ) return Plugin_Continue;
  if( !client )
    return Plugin_Continue;

  if( !g_playerData[client].bIsInRun ) return Plugin_Continue;

  g_playerData[client].nJumps++;
  return Plugin_Continue;
}

public Action OnTakeDamage( int client, int& attacker, int& inflictor, float& damage, int& damagetype ) {
  if( !g_isKZ ) return Plugin_Continue;

  if( damagetype & DMG_FALL || damagetype & DMG_BULLET )
    return Plugin_Handled;

  if( attacker > 0 && attacker < MaxClients ) {
    damage = 0.0;
  }

  return Plugin_Continue;
}

public Action Event_PlayerSpawn( Event e, const char[] name, bool dontBroadcast ) {
  int client = GetClientOfUserId( e.GetInt( "userid" ) );
  if( !g_isKZ ) return Plugin_Continue;

  if( !client )
    return Plugin_Continue;

  float origin[3];
  GetClientAbsOrigin( client, origin );

  float angle[3];
  GetClientAbsAngles( client, angle );

  Array_Copy( origin, g_playerData[client].vStartPoint, 3 );
  Array_Copy( angle, g_playerData[client].vStartAngle, 3 );

  if( g_isKZ ) {
    SetEntProp( client, Prop_Send, "m_CollisionGroup", 2 );
    ShowCheckpointMenu( client, true );

    char cookie[32];
    g_hideWeaponCookie.Get( client, cookie, sizeof(cookie) );

    bool draw = !StringToInt( cookie );
    g_playerData[client].bShowViewmodel = draw;
    SetEntProp( client, Prop_Send, "m_bDrawViewmodel", draw );
  }

  return Plugin_Continue;
}

public int TopTimesMenuHandler( Menu menu, MenuAction ma, int client, int nItem ) {
  if( ma == MenuAction_Cancel ) {
    if( g_playerData[client].bShowingMenu ) {
      ShowCheckpointMenu( client, g_isKZ );
    }
  }
  else if( ma == MenuAction_End ) {
    delete menu;
  }
  
  return 0;
}

public void ShowTopNubTimes( int client ) {  
  Menu menu = CreateMenu( TopTimesMenuHandler, MenuAction_Start );
  int max = g_topTime > 50 ? 50 : g_topTime;
  for( int i = 0; i < max; i++ ) {
    float time = g_times[i].fFinalTime;
    int hours = RoundToFloor( time ) / 3600;
    int minutes = RoundToFloor( time ) / 60;
    int seconds = RoundToFloor( time ) - hours * 3600 - minutes * 60;
    int milliseconds = RoundToFloor( (time - RoundToFloor( time )) * 1000 );

    char buf[256];
    Format( buf, sizeof(buf), "%d. %s - ", i + 1, g_times[i].sName );
    if( hours > 0 )
      Format( buf, sizeof(buf), "%s%d:%02d:%02d.%03d", buf, hours, minutes, seconds, milliseconds );
    else
      Format( buf, sizeof(buf), "%s%d:%02d.%03d", buf, minutes, seconds, milliseconds );

    Format( buf, sizeof(buf), "%s (%d TP, %d jumps)", buf, g_times[i].nTeleports, g_times[i].nJumps );
    menu.AddItem( "button", buf, ITEMDRAW_DISABLED );
  }

  DisplayMenu( menu, client, MENU_TIME_FOREVER );
}

public void ShowTopProTimes( int client ) {
  Menu menu = CreateMenu( TopTimesMenuHandler, MenuAction_Start );
  int it = 0;
  int max = g_topTime > 50 ? 50 : g_topTime;
  for( int i = 0; i < max; i++ ) {
    if( g_times[i].nTeleports > 0 )
      continue;

    float time = g_times[i].fFinalTime;
    int hours = RoundToFloor( time ) / 3600;
    int minutes = RoundToFloor( time ) / 60;
    int seconds = RoundToFloor( time ) - hours * 3600 - minutes * 60;
    int milliseconds = RoundToFloor( (time - RoundToFloor( time )) * 1000 );

    char buf[256];
    Format( buf, sizeof(buf), "%d. %s - ", it + 1, g_times[i].sName );
    if( hours > 0 )
      Format( buf, sizeof(buf), "%s%d:%02d:%02d.%03d", buf, hours, minutes, seconds, milliseconds );
    else
      Format( buf, sizeof(buf), "%s%d:%02d.%03d", buf, minutes, seconds, milliseconds );
    Format( buf, sizeof(buf), "%s (%d TP, %d jumps)", buf, g_times[i].nTeleports, g_times[i].nJumps );

    menu.AddItem( "button", buf, ITEMDRAW_DISABLED );
    
    ++it;
  }

  DisplayMenu( menu, client, MENU_TIME_FOREVER );
}

public int MaptopMenuHandler( Menu menu, MenuAction ma, int client, int nItem ) {
  if( ma == MenuAction_Select ) {
    switch( nItem ) {
      case 0: { ShowTopProTimes( client ); }
      case 1: { ShowTopNubTimes( client ); }
    }
  } else if( ma == MenuAction_Cancel ) {
    if( g_playerData[client].bShowingMenu )
      ShowCheckpointMenu( client, g_isKZ );
  }
  else if( ma == MenuAction_End ) {
    delete menu;
  }

  return 0;
}

public Action Command_Maptop( int client, int args ) {
  if( !g_isKZ ) return Plugin_Handled;

  Menu menu = CreateMenu( MaptopMenuHandler, MenuAction_Start );
  AddMenuItem( menu, "button", "top 50 PRO" );
  AddMenuItem( menu, "button", "top 50 NUB" ); 
  DisplayMenu( menu, client, MENU_TIME_FOREVER );

  return Plugin_Handled;
}

public Action Command_MyRank( int client, int args ) {
  if( !g_isKZ ) return Plugin_Handled;

  char clientSteamId[32];
  GetClientAuthId( client, AuthId_Engine, clientSteamId, sizeof(clientSteamId) );

  char name[64];
  GetClientName( client, name, sizeof(name) );

  int rank = -1;
  for( int i = 0; i < g_topTime; i++ ) {
    if( !strcmp( clientSteamId, g_times[i].sSteamid ) ) {
      rank = i + 1;
      break;
    }
  }

  if( rank == -1 ) {
    CPrintToChatAll( "[{green}kz{default}] {violet}%s {white}has no time on this map." );
    return Plugin_Handled;
  }

  float time = g_times[rank - 1].fFinalTime;
  int hours = RoundToFloor( time ) / 3600;
  int minutes = RoundToFloor( time ) / 60;
  int seconds = RoundToFloor( time ) - hours * 3600 - minutes * 60;
  int milliseconds = RoundToFloor( (time - RoundToFloor( time )) * 1000 );

  char buf[256];
  Format( buf, sizeof(buf), "[{green}kz{default}] {violet}%s {white}is ranked {cyan}#%d/%d{white} with a time of ", name, rank, g_topTime );
  if( hours > 0 )
    Format( buf, sizeof(buf), "%s%d:%02d:%02d.%03d", buf, hours, minutes, seconds, milliseconds );
  else
    Format( buf, sizeof(buf), "%s%d:%02d.%03d", buf, minutes, seconds, milliseconds );

  CPrintToChatAll( buf );
  return Plugin_Handled;
}

public Action Command_HideViewmodel( int client, int args ) {
  if( !g_isKZ ) return Plugin_Handled;

  bool draw = !!GetEntProp( client, Prop_Send, "m_bDrawViewmodel" );
  SetEntProp( client, Prop_Send, "m_bDrawViewmodel", !draw );

  char cookieStr[32];
  IntToString( draw, cookieStr, sizeof(cookieStr) );
  g_hideWeaponCookie.Set( client, cookieStr );

  g_playerData[client].bShowViewmodel = !draw;

  CPrintToChat( client, "[{green}kz{default}] viewmodel is now %s", !draw ? "shown" : "hidden" );
  return Plugin_Handled;
}

public Action Command_Noclip( int client, int args ) {
  if( !g_isKZ ) return Plugin_Handled;

  MoveType mv = GetEntityMoveType( client );
  if( mv != MOVETYPE_NOCLIP ) {
    SetEntityMoveType( client, MOVETYPE_NOCLIP );
    CPrintToChat( client, "[{green}kz{default}] noclip enabled." );
  } else {
    SetEntityMoveType( client, MOVETYPE_WALK );
    CPrintToChat( client, "[{green}kz{default}] noclip disabled." ); 
  }

  return Plugin_Handled;
}