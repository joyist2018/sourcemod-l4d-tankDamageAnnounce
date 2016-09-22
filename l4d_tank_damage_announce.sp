#include <sourcemod>

#pragma newdecls required
#pragma semicolon 1

public Plugin myinfo = {
        name = "Tank Damage Announce L4D2",
        author = "Griffin and Blade",
        description = "Announce damage dealt to tanks by survivors",
        version = "0.6.5d"
};

const           TEAM_SURVIVOR               = 2;
const           TEAM_INFECTED               = 3;
const           ZOMBIECLASS_TANK            = 8;                // Zombie class of the tank, used to find tank after he have been passed to another player
bool			g_bEnabled                  = true;
bool			g_bAnnounceTankDamage       = false;            // Whether or not tank damage should be announced
bool			g_bIsTankInPlay             = false;            // Whether or not the tank is active
int				g_iOffset_Incapacitated     = 0;                // Used to check if tank is dying
int				g_iTankClient               = 0;                // Which client is currently playing as tank
int				g_iLastTankHealth           = 0;                // Used to award the killing blow the exact right amount of damage
int				g_iSurvivorLimit			= 4;                // For survivor array in damage print
int				g_iDamage[MAXPLAYERS + 1];
int				g_iFireDamage;
float			g_fMaxTankHealth            = 6000.0;
Handle			g_hCvarEnabled              = null;
Handle			g_hCvarTankHealth           = null;
Handle			g_hCvarSurvivorLimit        = null;

Handle			g_hGameMode;
Handle			g_hGameDifficulty;
char 			g_sGameMode[128];
char 			g_sGameDifficulty[128];

public void OnPluginStart()
{
	g_bIsTankInPlay = false;
	g_bAnnounceTankDamage = false;
	g_iTankClient = 0;
	ClearTankDamage();
	HookEvent("tank_spawn", Event_TankSpawn);
	HookEvent("player_death", Event_PlayerKilled);
	HookEvent("round_start", Event_RoundStart);
	HookEvent("round_end", Event_RoundEnd);
	HookEvent("player_hurt", Event_PlayerHurt);
 
	g_hCvarEnabled = CreateConVar("l4d_tankdamage_enabled", "1", "Announce damage done to tanks when enabled", FCVAR_SPONLY|FCVAR_NOTIFY, true, 0.0, true, 1.0);
	g_hCvarSurvivorLimit = FindConVar("survivor_limit");
	g_hCvarTankHealth = FindConVar("z_tank_health");
 
	HookConVarChange(g_hCvarEnabled, Cvar_Enabled);
	HookConVarChange(g_hCvarSurvivorLimit, Cvar_SurvivorLimit);
	HookConVarChange(g_hCvarTankHealth, Cvar_TankHealth);
 
	g_hGameMode = FindConVar("mp_gamemode");
	g_hGameDifficulty = FindConVar("z_difficulty");
 
	g_bEnabled = GetConVarBool(g_hCvarEnabled);
	CalculateTankHealth();
 
	g_iOffset_Incapacitated = FindSendPropInfo("Tank", "m_isIncapacitated");
}
     
public void OnMapStart()
{
        // In cases where a tank spawns and map is changed manually, bypassing round end
        ClearTankDamage();
}
     
public void OnClientDisconnect_Post(int client)
{
        if (!g_bIsTankInPlay || client != g_iTankClient) return;
        CreateTimer(0.1, Timer_CheckTank, client); // Use a delayed timer due to bugs where the tank passes to another player
}
     
public void Cvar_Enabled(Handle convar, const char[] oldValue, const char[] newValue)
{
        g_bEnabled = StringToInt(newValue) > 0 ? true:false;
}
     
public void Cvar_SurvivorLimit(Handle convar, const char[] oldValue, const char[] newValue)
{
        g_iSurvivorLimit = StringToInt(newValue);
}
     
public void Cvar_TankHealth(Handle convar, const char[] oldValue, const char[] newValue)
{
	CalculateTankHealth();
}
     
void CalculateTankHealth()
{
	g_fMaxTankHealth = GetConVarFloat(g_hCvarTankHealth);
	if (g_fMaxTankHealth <= 0.0) g_fMaxTankHealth = 1.0; // No dividing by 0!
	
	GetConVarString(g_hGameMode, g_sGameMode, sizeof(g_sGameMode));
	GetConVarString(g_hGameDifficulty, g_sGameDifficulty, sizeof(g_sGameDifficulty));

	if (StrContains(g_sGameMode, "coop", false) != -1)
	{
		if (StrContains(g_sGameDifficulty, "easy", false) != -1)
			g_fMaxTankHealth = 3000.0;
		if (StrContains(g_sGameDifficulty, "normal", false) != -1)
			g_fMaxTankHealth = 4000.0;
		if (StrContains(g_sGameDifficulty, "hard", false) != -1)
			g_fMaxTankHealth = 8000.0;
		if (StrContains(g_sGameDifficulty, "impossible", false) != -1)
			g_fMaxTankHealth = 8000.0;
	}
	else
		g_fMaxTankHealth = 6000.0;
		
	// PrintToChatAll("CalculateTankHealth - gamemode: %s difficulty: %s tankhealth: %f", g_sGameMode, g_sGameDifficulty, g_fMaxTankHealth);
}
     
public void Event_PlayerHurt(Handle event, const char[] name, bool dontBroadcast)
{
	if (!g_bIsTankInPlay) return; // No tank in play; no damage to record
 
  	char WeaponUsed[32];
	GetEventString(event, "weapon", WeaponUsed, 32);
 
	int victim = GetClientOfUserId(GetEventInt(event, "userid"));
	if (victim != GetTankClient() ||        // Victim isn't tank; no damage to record
			IsTankDying()                                   // Something buggy happens when tank is dying with regards to damage
									) return;
 
	int attacker = GetClientOfUserId(GetEventInt(event, "attacker"));
	// We only care about damage dealt by survivors, though it can be funny to see
	// claw/self inflicted hittable damage, so maybe in the future we'll do that
	if (attacker == 0 ||                                                    // Damage from world?
			!IsClientInGame(attacker) ||                            // Not sure if this happens
			GetClientTeam(attacker) != TEAM_SURVIVOR
									) return;

	if (StrEqual(WeaponUsed, "inferno", false)) // Damage is fire-type
		g_iFireDamage += GetEventInt(event, "dmg_health");
	else
		g_iDamage[attacker] += GetEventInt(event, "dmg_health");

	g_iLastTankHealth = GetEventInt(event, "health");
}
     
public void Event_PlayerKilled(Handle event, const char[] name, bool dontBroadcast)
{
	if (!g_bIsTankInPlay) return; // No tank in play; no damage to record
 
	int victim = GetClientOfUserId(GetEventInt(event, "userid"));
	if (victim != g_iTankClient) return;
 
	// Award the killing blow's damage to the attacker; we don't award
	// damage from player_hurt after the tank has died/is dying
	// If we don't do it this way, we get wonky/inaccurate damage values
	int attacker = GetClientOfUserId(GetEventInt(event, "attacker"));
	if (attacker && IsClientInGame(attacker)) g_iDamage[attacker] += g_iLastTankHealth;
 
	// Damage announce could probably happen right here...
	CreateTimer(0.1, Timer_CheckTank, victim); // Use a delayed timer due to bugs where the tank passes to another player
}
     
public void Event_TankSpawn(Handle event, const char[] name, bool dontBroadcast)
{
	int client = GetClientOfUserId(GetEventInt(event, "userid"));
	g_iTankClient = client;
 
	if (g_bIsTankInPlay) return; // Tank passed
 
	// New tank, damage has not been announced
	CalculateTankHealth();
	g_bAnnounceTankDamage = true;
	g_bIsTankInPlay = true;
	// Set health for damage print in case it doesn't get set by player_hurt (aka no one shoots the tank)
	g_iLastTankHealth = GetClientHealth(client);
}
     
public void Event_RoundStart(Handle event, const char[] name, bool dontBroadcast)
{
        g_bIsTankInPlay = false;
        g_iTankClient = 0;
        ClearTankDamage(); // Probably redundant
}
     
// When survivors wipe or juke tank, announce damage
public void Event_RoundEnd(Handle event, const char[] name, bool dontBroadcast)
{
        // But only if a tank that hasn't been killed exists
        if (g_bAnnounceTankDamage)
        {
                PrintRemainingHealth();
                PrintTankDamage();
        }
        ClearTankDamage();
}
     
public Action Timer_CheckTank(Handle timer, any oldtankclient)
{
        if (g_iTankClient != oldtankclient) return; // Tank passed
     
        int tankclient = FindTankClient();
        if (tankclient && tankclient != oldtankclient)
        {
                g_iTankClient = tankclient;
     
                return; // Found tank, done
        }
     
        if (g_bAnnounceTankDamage) PrintTankDamage();
        ClearTankDamage();
        g_bIsTankInPlay = false; // No tank in play
}
     
bool IsTankDying()
{
        int tankclient = GetTankClient();
        if (!tankclient) return false;
     
		// return bool:GetEntData(tankclient, g_iOffset_Incapacitated);
        return GetEntData(tankclient, g_iOffset_Incapacitated) > 0;
}
     
void PrintRemainingHealth()
{
        if (!g_bEnabled) return;
        int tankclient = GetTankClient();
        if (!tankclient) return;
     
        char name[MAX_NAME_LENGTH];
        if (IsFakeClient(tankclient)) name = "AI";
        else GetClientName(tankclient, name, sizeof(name));
        PrintToChatAll("\x01[SM] Tank (\x03%s\x01) had \x05%d\x01 health remaining", name, g_iLastTankHealth);
}
     
void PrintTankDamage()
{
	if (!g_bEnabled) return;
	
	PrintToChatAll("Tank");

	int client;
	int percent_total; // Accumulated total of calculated percents, for fudging out numbers at the end
	int damage_total; // Accumulated total damage dealt by survivors, to see if we need to fudge upwards to 100%
	int survivor_index = -1;
	
	int[] survivor_clients = new int[g_iSurvivorLimit];  // Array to store survivor client indexes in, for the display iteration
	// new survivor_clients[g_iSurvivorLimit]; // Array to store survivor client indexes in, for the display iteration
		   
	int percent_damage, damage;
	for (client = 1; client <= MaxClients; client++)
	{
			if (!IsClientInGame(client) || GetClientTeam(client) != TEAM_SURVIVOR) continue;
			survivor_index++;
			survivor_clients[survivor_index] = client;
			damage = g_iDamage[client];
			damage_total += damage;
			percent_damage = GetDamageAsPercent(damage);
			percent_total += percent_damage;
	}
	SortCustom1D(survivor_clients, g_iSurvivorLimit, SortByDamageDesc);
 
	int percent_adjustment;
	// Percents add up to less than 100% AND > 99.5% damage was dealt to tank
	if ((percent_total < 100 &&
			float(damage_total) > (g_fMaxTankHealth - (g_fMaxTankHealth / 200.0)))
			)
	{
			percent_adjustment = 100 - percent_total;
	}
 
	int last_percent = 100; // Used to store the last percent in iteration to make sure an adjusted percent doesn't exceed the previous percent
	int adjusted_percent_damage;
	for (int i; i <= survivor_index; i++)
	{
			client = survivor_clients[i];
			damage = g_iDamage[client];
			percent_damage = GetDamageAsPercent(damage);
			// Attempt to adjust the top damager's percent, defer adjustment to next player if it's an exact percent
			// e.g. 3000 damage on 6k health tank shouldn't be adjusted
			if (percent_adjustment != 0 && // Is there percent to adjust
					damage > 0 &&  // Is damage dealt > 0%
					!IsExactPercent(damage) // Percent representation is not exact, e.g. 3000 damage on 6k tank = 50%
					)
			{
					adjusted_percent_damage = percent_damage + percent_adjustment;
					if (adjusted_percent_damage <= last_percent) // Make sure adjusted percent is not higher than previous percent, order must be maintained
					{
							percent_damage = adjusted_percent_damage;
							percent_adjustment = 0;
					}
			}
			PrintToChatAll("\x05%4d\x01 [\x04%d%%\x01]: \x03%N\x01", damage, percent_damage, client);
	}
	if (g_iFireDamage)
		PrintToChatAll("\x05%4d\x01 [\x04%d%%\x01] fire damage", g_iFireDamage, GetDamageAsPercent(g_iFireDamage) + 1);
}
     
void ClearTankDamage()
{
	g_iLastTankHealth = 0;
	for (int i = 1; i <= MaxClients; i++) { g_iDamage[i] = 0; }
	g_iFireDamage = 0;
	g_bAnnounceTankDamage = false;
}
     
     
int GetTankClient()
{
        if (!g_bIsTankInPlay) return 0;
     
        int tankclient = g_iTankClient;
     
        if (!IsClientInGame(tankclient)) // If tank somehow is no longer in the game (kicked, hence events didn't fire)
        {
                tankclient = FindTankClient(); // find the tank client
                if (!tankclient) return 0;
                g_iTankClient = tankclient;
        }
     
        return tankclient;
}
     
int FindTankClient()
{
        for (int client = 1; client <= MaxClients; client++)
        {
                if (!IsClientInGame(client) ||
                        GetClientTeam(client) != TEAM_INFECTED ||
                        !IsPlayerAlive(client) ||
                        GetEntProp(client, Prop_Send, "m_zombieClass") != ZOMBIECLASS_TANK)
                        continue;
     
                return client; // Found tank, return
        }
        return 0;
}
     
int GetDamageAsPercent(int damage)
{
        return RoundToFloor(FloatMul(FloatDiv(float(damage), g_fMaxTankHealth), 100.0));
}
     
bool IsExactPercent(int damage)
{
        return (FloatAbs(float(GetDamageAsPercent(damage)) - FloatMul(FloatDiv(float(damage), g_fMaxTankHealth), 100.0)) < 0.001) ? true:false;
}
     
public int SortByDamageDesc(int elem1, int elem2, const array[], Handle hndl)
{
        // By damage, then by client index, descending
        if (g_iDamage[elem1] > g_iDamage[elem2]) return -1;
        else if (g_iDamage[elem2] > g_iDamage[elem1]) return 1;
        else if (elem1 > elem2) return -1;
        else if (elem2 > elem1) return 1;
        return 0;
}