-module(teles_data_manager).
-behaviour(gen_server).
-export([start_link/1]).
-export([init/1, handle_call/3, handle_cast/2, handle_info/2,
         terminate/2, code_change/3]).
-export([get_agent/1, get_agents/1, list_spaces/0, list_objects/1,
         list_associations/2]).

-record(state, {
        num_agents=1, % Number of agents per space
        agents        % Space -> {[agent()], [agent()]}
    }).

start_link(NumAgents) ->
    gen_server:start_link({local, ?MODULE}, ?MODULE, [NumAgents], []).

%% ------------------------------------------------------------------
%% gen_server Function Definitions
%% ------------------------------------------------------------------

init([NumAgents]) ->
    State = #state{num_agents=NumAgents, agents=dict:new()},
    {ok, State}.


handle_call({create_space, Space}, _From, State) ->
    {_, State1} = agents_for_space(Space, State),
    {reply, ok, State1};


handle_call({delete_space, Space}, _From, State) ->
    Agents = State#state.agents,
    {Resp, NewState} = case dict:find(Space, Agents) of
        error -> {not_found, State};
        {ok, {Pids1, Pids2}} ->
            % Instruct all agents to shutdown
            Pids = lists:append(Pids1, Pids2),
            [gen_server:cast(P, stop) || P <- Pids],

            % Remove them from the list
            {ok, State#state{agents=dict:erase(Space, Agents)}}
    end,
    {reply, Resp, NewState};


handle_call(list_spaces, _From, State) ->
    Agents = State#state.agents,
    Spaces = dict:fetch_keys(Agents),
    {reply, Spaces, State};


handle_call({get_agent, Space}, _From, State) ->
    {Pid, State1} = unshift_agent(Space, State),
    {reply, {ok, Pid}, State1};


handle_call({get_agents, Space}, _From, State) ->
    {{Pid1, Pids2}, State1} = agents_for_space(Space, State),
    Pids = lists:append(Pid1, Pids2),
    {reply, {ok, Pids}, State1}.


handle_cast(_Msg, State) ->
    {noreply, State}.


handle_info(_Info, State) ->
    {noreply, State}.


terminate(_Reason, _State) -> ok.
code_change(_OldVsn, State, _Extra) -> {ok, State}.

%% ------------------------------------------------------------------
%% Internal Function Definitions
%% ------------------------------------------------------------------

% Returns a list of pids for a space if they exist,
% or starts them otherwise.
-spec agents_for_space(term(), #state{}) -> {{[pid()], [pid()]}, #state{}}.
agents_for_space(Space, State) ->
    Agents = State#state.agents,
    case dict:find(Space, Agents) of
        {ok, Val} -> {Val, State};
        error ->
            Num = State#state.num_agents,
            Pids = teles_data_manager_sup:star_agents(Num, Space),
            NewAgents = dict:put(Space, {Pids, []}, Agents),
            NewState = State#state{agents=NewAgents},
            {{Pids, []}, NewState}
    end.


% Returns the next agent pid, causes a state change.
% This causes requests to load balance across agents.
-spec unshift_agent(term(), #state{}) -> {pid(), #state{}}.
unshift_agent(Space, State) ->
    AgentsDict = State#state.agents,
    Agents = agents_for_space(Space, State),
    case Agents of
        % If there is only a single PID, we can save time and
        % avoid the state updates
        {[A], []} -> {A, State};

        % Pop from the left side while we can, append to right
        {[A | More], Other} ->
            NewAgents = dict:store(Space, {More, [A | Other]}, AgentsDict),
            NewState = State#state{agents=NewAgents},
            {A, NewState};

        % Reverse right side and move to left
        {[], Ready} ->
            [A | More] = lists:reverse(Ready),
            NewAgents = dict:store(Space, {More, [A]}, AgentsDict),
            NewState = State#state{agents=NewAgents},
            {A, NewState}
    end.


%%%% ------------------------------------------------------------------
%% External Function Definitions
%% ------------------------------------------------------------------

% Gets the Pid of an agent for a space
get_agent(Space) ->
    {ok, Pid} = gen_server:call({local, ?MODULE}, {get_agent, Space}),
    Pid.


% Gets all the Pids for agents for a space
get_agents(Space) ->
    {ok, Pids} = gen_server:call({local, ?MODULE}, {get_agents, Space}),
    Pids.


% Creates a new space
create_space(Space) ->
    gen_server:call({local, ?MODULE}, {create_space, Space}).


% Deletes a space
delete_space(Space) ->
    gen_server:call({local, ?MODULE}, {delete_space, Space}).


% Lists the object keys in a given space
list_spaces() ->
    gen_server:call({local, ?MODULE}, list_spaces).


% Lists the object keys in a given space
list_objects(Space) ->
    Agent = get_agent(Space),
    gen_server:call(Agent, list_objects).


% Lists associations of an object
list_associations(Space, OID) ->
    Agent = get_agent(Space),
    gen_server:call(Agent, {list_associations, OID}).

