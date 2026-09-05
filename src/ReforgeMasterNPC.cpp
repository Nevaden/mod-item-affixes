// Reforge NPC (docs/REFORGE_PLAN.md, Stage 3). Blurb + two gossip options:
// "Reforge" opens the reforge frame (ReforgeUI.lua, Stage 4); "Progression"
// opens the Player Progression frame (ProgressionUI.lua) as an alternative
// to typing /prog. Both are also reachable directly via slash command
// (/reforge, /prog) -- the NPC is a convenience, not a requirement, for
// either one.

#include "CreatureScript.h"
#include "ItemAffix.h"
#include "Player.h"
#include "ScriptedGossip.h"

enum ReforgeMasterGossip
{
    GOSSIP_ACTION_REFORGE     = GOSSIP_ACTION_INFO_DEF + 1,
    GOSSIP_ACTION_PROGRESSION = GOSSIP_ACTION_INFO_DEF + 2,
};

class npc_reforge_master : public CreatureScript
{
public:
    npc_reforge_master() : CreatureScript("npc_reforge_master") {}

    bool OnGossipHello(Player* player, Creature* creature) override
    {
        AddGossipItemFor(player, GOSSIP_ICON_CHAT, "Reforge", GOSSIP_SENDER_MAIN, GOSSIP_ACTION_REFORGE);
        AddGossipItemFor(player, GOSSIP_ICON_CHAT, "Progression", GOSSIP_SENDER_MAIN, GOSSIP_ACTION_PROGRESSION);
        SendGossipMenuFor(player, player->GetGossipTextId(creature), creature->GetGUID());
        return true;
    }

    bool OnGossipSelect(Player* player, Creature* /*creature*/, uint32 /*sender*/, uint32 action) override
    {
        if (action == GOSSIP_ACTION_REFORGE)
        {
            CloseGossipMenuFor(player);
            sItemAffixMgr->SendAddonMsg(player, "REFORGE_OPEN");
        }
        else if (action == GOSSIP_ACTION_PROGRESSION)
        {
            CloseGossipMenuFor(player);
            sItemAffixMgr->SendAddonMsg(player, "PROG_OPEN");
        }
        return true;
    }
};

void AddSC_npc_reforge_master()
{
    new npc_reforge_master();
}
