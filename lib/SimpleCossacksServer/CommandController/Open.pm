package SimpleCossacksServer::CommandController::Open;
use Mouse;
use Coro::LWP;
use LWP;
use JSON;
use AnyEvent::IO;
use String::Escape();
use Digest::MD5 qw(md5);
use URI();
use URI::QueryParam();
use feature 'state';

my @PUBLIC = qw[
  enter try_enter startup resize games rooms_table_dgl new_room_dgl reg_new_room
  join_game join_pl_cmd user_details users_list games_list direct direct_ping 
  direct_join room_info_dgl discord_dlg register started_room_message logout_player
  get_players_list sendCreateGameRequest sendJoinGameRequest sendLeaveGameRequest
];


my %PUBLIC = map { $_ => 1 } @PUBLIC;
sub public {
  my($self, $method) = @_;
  return $PUBLIC{$method};
}

sub enter {
  my($self, $h, $p) = @_;
  if($h->connection->data->{account}) {
    $self->logout_player($h);
  }
  $h->show('enter.cml', {type => 'login_view'});
}

my $ua = LWP::UserAgent->new();
sub try_enter {
  my($self, $h, $p) = @_;
  my $nick = $p->{NICK};
  my $type = $p->{TYPE} // '';
  # $h->connection->data->{dev} = ($nick =~ s/#dev4231$//);
  if($p->{RESET}) {
    $self->logout_player($h);
    $h->connection->data->{account} = undef;
    $h->show('enter.cml');
  } elsif($p->{LOGGED_IN}) {
    if($h->connection->data->{account}) {
      $nick = $h->connection->data->{account}{login};
      $nick =~ s/[^\[\]\w-]+//g;
      $h->server->post_account_action($h, 'enter');
      $self->_success_enter($h, $p, $nick);
    } else {
      $h->show('enter.cml');  
    }
  } {
    if(!defined($nick) || $nick eq '') {
      $h->show('error_enter.cml', { error_text => 'Enter nick' });
    } else {
      $nick = substr($nick, 0, 25) if length($nick) > 25;

      my $password = $p->{PASSWORD};
      my $email = $p->{EMAIL};
      my $isLogin = $type eq 'login_view';
      
      my $account_data = $isLogin ? {
        nickName => $nick,
        email => '',
        passwordHash => $password,
      } : {
        nickName => $nick,
        email => $email,
        passwordHash => $password,
      };

      my $targetPage = $isLogin ? 'enter.cml' : 'register.cml';
      
      my $result = $isLogin ? $self->_send_json_request($h, "http://localhost:8080/players/login", "POST", $account_data) :
        $self->_send_json_request($h, "http://localhost:8080/players/register", "PUT", $account_data);
      unless ($result) {
        $h->show($targetPage, { error => "problem with server", type => $type });
        return;
      }
      unless ($isLogin) {
        unless($result->{loginStatus} eq 'SUCCESS') {
          $h->show($targetPage, { error => $result->{message}, type => $type });
          return;
        }

        $result = $self->_send_json_request($h, "http://localhost:8080/players/login", "POST", $account_data);
        unless ($result) {
          $h->show($targetPage, { error => "problem with server", type => $type });
          return;
        }
      }

      unless($result->{loginStatus} eq 'SUCCESS') {
        $h->show($targetPage, { error => $result->{message}, type => $type });
        $h->log->info($h->connection->log_message . " " . $h->req->ver . " #authenticate unsuccessfull with " . lc($type) . " login " . String::Escape::printable($nick));
      } else {
        my $account_data_saved = {
          nickName => $nick,
          login => $nick,
          token => $result->{token},
        };
        $h->connection->data->{account} = $account_data_saved;
        $self->_success_enter($h, $p, $nick);
      }
    }
  }
}

sub _send_json_request {
  my($self, $h, $url, $method, $data) = @_;

  my $request = HTTP::Request->new($method, $url);
  $request->header('Content-Type' => 'application/json');
  $request->content(encode_json($data));

  my $response = $ua->request($request);

  unless($response->is_success) {
    $h->log->error("bad response from $url with body $data: " . $response->status_line);
    return undef;
  }

  my $result = eval { JSON::from_json($response->decoded_content) } or do {
    $h->log->error("bad json from $url");
    return undef;
  };
  return $result;
}

sub logout_player {
    my ($self, $h) = @_;
    if (my $account = $h->connection->data->{account}) {
      my $server = $h->server;
      return unless $account && $account->{token};

      my $token = $account->{token};
      my $nick = $account->{nickName};

      $server->log->info(" #logout from account " . String::Escape::printable($nick) . " with token " . $token);

      my $url = "http://localhost:8080/players/logout";
      my $request = HTTP::Request->new('POST', $url);
      $request->header('Content-Type' => 'application/json');
      $request->content($token);
      $ua->request($request);
  }
  $h->connection->data->{account} = undef;
  if(my $id = $h->connection->data->{id}) {
    $h->server->leave_room($id);
    delete $h->server->data->{players}{$id};
  } 
}

sub sendCreateGameRequest {
    my ($self, $h, $p) = @_;
    my $player_id = $p->{playerId};
    my $game_name = $p->{gameName};
    my $account = $h->connection->data->{account};

    unless ($account && $account->{token}) {
        $h->log->error("No account or token found for creating a game.");
        return;
    }

    my $player_token = $account->{token};

    my $request_body = {
        gameName   => $game_name,
        playerToken => $player_token,
    };

    my $result = $self->_send_json_request($h, "http://localhost:8080/players/game-create", "POST", $request_body);

    if ($result) {
        $h->log->info("Successfully sent game creation request for player $player_id. Response: " . encode_json($result));
    } else {
        $h->log->error("Failed to send game creation request for player $player_id.");
    }
}

sub sendJoinGameRequest {
    my ($self, $h, $p) = @_;
    my $player_id = $p->{playerId};
    my $game_name = $p->{gameName};
    my $account = $h->connection->data->{account};

    unless ($account && $account->{token}) {
        $h->log->error("No account or token found for joining a game.");
        return;
    }

    my $player_token = $account->{token};

    my $request_body = {
        gameName   => $game_name,
        playerToken => $player_token,
    };

    my $result = $self->_send_json_request($h, "http://localhost:8080/players/game-join", "POST", $request_body);

    if ($result) {
        $h->log->info("Successfully sent game join request for player $player_id. Response: " . encode_json($result));
    } else {
        $h->log->error("Failed to send game join request for player $player_id.");
    }
}

sub sendLeaveGameRequest {
    my ($self, $h, $p) = @_;
    my $player_id = $p->{playerId};
    my $game_name = $p->{gameName};
    my $account = $h->connection->data->{account};

    unless ($account && $account->{token}) {
        $h->log->error("No account or token found for leaving a game.");
        return;
    }

    my $player_token = $account->{token};

    my $request_body = {
        gameName   => $game_name,
        playerToken => $player_token,
    };

    my $result = $self->_send_json_request($h, "http://localhost:8080/players/game-leave", "POST", $request_body);

    if ($result) {
        $h->log->info("Successfully sent game leave request for player $player_id. Response: " . encode_json($result));
    } else {
        $h->log->error("Failed to send game leave request for player $player_id.");
    }
}

sub _success_enter {
  my($self, $h, $p, $nick) = @_;
  my $serverData = $h->server->data;
  my $id;
  unless($h->connection->data->{id}) {
    $id = ++$serverData->{last_player_id};
    $h->connection->data->{id} = $id;
    $h->connection->connection_by_pid($id => $h->connection);
    # $h->log->warn("#success_enter connectionDataId: " . $h->connection->data->{id});
  } else {
    $id = $h->connection->data->{id};
    $h->server->leave_room( $id );
  }
  $h->connection->data->{nick} = $nick;
  my $account_data = $h->connection->data->{account};
  $h->log->info(
    $h->connection->log_message . " " . $h->req->ver . " #enter" 
    . ( $account_data ?
      " with account " . String::Escape::printable("$account_data->{token} $account_data->{nickName}")
      : ""
    ) . " nick: " . String::Escape::printable($nick) . " id: " . $id
  );
  $serverData->{players}{$id}{nick} = $nick;
  $serverData->{players}{$id}{account} = $account_data;
  $serverData->{players}{$id}{connected_at} = $h->connection->ctime;
  $serverData->{players}{$id}{id} = $id;
  $serverData->{players}{$id}{account} = $h->connection->data->{account};
  my $height = $p->{HEIGHT} =~ /^\d+$/ ? $p->{HEIGHT} : $h->connection->data->{height};
  $h->connection->data->{height} = $height;
  my $size = $height && $height > int(314 + (419 - 314)/2) ? 'large' : 'small';
  $h->show('ok_enter.cml', { nick => $nick, id => $id, window_size => $size });
}

sub startup {
  my($self, $h, $p) = @_;
  my $size = $h->connection->data->{height} && $h->connection->data->{height} > int(314 + (419 - 314)/2) ? 'large' : 'small';
  my $gg_cup = $h->server->load_gg_cup();
  $h->show('startup.cml', { window_size => $size, gg_cup => $gg_cup });
}

sub resize {
  my($self, $h, $p) = @_;
  my $height = $p->{height};
  $h->connection->data->{height} = $height;
  my $size = $height > int(314 + (419 - 314)/2) ? 'large' : 'small';
  if($size eq 'large') {
    $h->push_command(LW_show => "<RESIZE>\n#large\n<RESIZE>");
  } else {
    $h->push_command(LW_show => "<RESIZE>\n<RESIZE>");
  }
}

sub games {
  my $self = shift;
  $self->startup(@_);
}

sub new_room_dgl {
  my($self, $h, $p) = @_;
  if(!$p->{ASTATE}) {
    $self->_error($h, "You can not create or join room!\nYou are already participate in some room\nPlease disconnect from that room first to create a new one");
  } else {
    $h->show('new_room_dgl.cml');
  }
}

sub reg_new_room {
  my($self, $h, $p) = @_;
  if(!$p->{ASTATE}) {
    $self->_error($h, "You can not create or join room!\nYou are already participate in some room\nPlease disconnect from that room first to create a new one");
  } elsif($p->{VE_TITLE} eq '' || $p->{VE_TITLE} =~ /[\x00-\x1F\x7F]/ || $p->{VE_TITLE} =~ /^\s*$/) {
    $h->show('confirm_dgl.cml', {
      header  => "Error",
      text    => "Illegal title!\nPress Edit button to check title",
      ok_text => "Edit",
      command => "GW|open&new_room_dgl.dcml&ASTATE=<%ASTATE>",
    });
  } elsif(!$h->connection->data->{id} || !$h->connection->data->{nick}) {
    $self->_error($h, "Your was disconnected from the server. Enter again.");
  } else {
    my $player_id = $h->connection->data->{id};
    $h->server->leave_room( $player_id );
    my $rooms = ( $h->server->data->{dbtbl}{ "ROOMS_V" . $h->req->ver } //= [] );
    $h->server->data->{last_room} ||= 1;
    my $room_id = ++$h->server->data->{last_room};
    my $level = $p->{VE_LEVEL} == 3 ? 'Hard' : $p->{VE_LEVEL} == 2 ? 'Normal' : $p->{VE_LEVEL} == 1 ? 'Easy' : 'For all';
    my $title = $p->{VE_TITLE};
    $title = substr($title, 0, 60) if length($title) > 60;
    s/^\s+//, s/\s+$// for $title;
    my $maxPlayers = ($p->{VE_TYPE} == 1 ? 2 : $p->{VE_MAX_PL}+2);
    my $row = [ $room_id, (length $p->{VE_PASSWD} ? '#' : ''), $title, $h->connection->data->{nick}, $p->{VE_TYPE}, "1/".($maxPlayers), $h->req->ver, $h->connection->int_ip, sprintf("0%X", 0xFFFFFFFF - $room_id) ];
    my $ctlsum = $h->server->_room_control_sum($row);
    my $room = {
      row            => $row,
      id             => $room_id,
      title          => $title,
      password       => $p->{VE_PASSWD} // '',
      host_id        => $player_id,
      host_addr      => $h->connection->ip,
      host_addr_int  => $h->connection->int_ip,
      players_count  => 1,
      players        => { $player_id => { %{$h->server->data->{players}->{$player_id}} } },
      players_time   => { $player_id => time },
      max_players    => $maxPlayers,
      ver            => $h->req->ver,
      level          => int($p->{VE_LEVEL}),
      ctime          => time,
      ctlsum         => $ctlsum,
    };
    push @$rooms, $room;
    $h->server->data->{rooms_by_ctlsum}->{ $room->{ctlsum} }  = $room;
    $h->server->data->{rooms_by_player}->{ $room->{host_id} } = $room;
    $h->server->data->{rooms_by_id}->{ $room->{id} }          = $room;
    $h->server->data->{alive_timers}{ $player_id } = AnyEvent->timer( after => 150, cb => sub {
      $h->server->command_controller($h)->not_alive($h, $player_id);
    } );
    $h->log->info($h->connection->log_message . " " . $h->req->ver . " #create room $room->{id} $room->{title}" );
    $h->show('reg_new_room.cml', { id => ($p->{VE_TYPE} ? "HB" : "") . $room_id, name => $room->{title}, max_pl => $room->{max_players} });
  }
}

sub room_info_dgl {
  my($self, $h, $p) = @_;
  if($p->{VE_RID} !~ /^\d+$/) {
    $h->push_command( LW_show => "<NGDLG>\n<NGDLG>");
    return;
  }
  my $room = $h->server->data->{rooms_by_id}{ $p->{VE_RID} };
  unless($room) {
    $self->_error($h, "The room is closed");
    return;
  }
  my $backto;
  if($p->{BACKTO} && $p->{BACKTO} eq 'user_details') {
    # $backto = 'open&user_details.dcml&ID=' . $h->connection->data->{id}; 
    # $h->log->warn("room_info_dgl: Set backto ID=" . $h->connection->data->{id});
  }
  if($room->{started} && ($h->connection->data->{dev} || $h->server->config->{show_started_room_info})) {
    state $nations = [qw<
      Bavaria
      Denmark
      Austria
      England
      France
      Netherlands
      Piemonte
      Portugal
      Prussia
      Russia
      Poland
      Saxony
      Spain
      Sweden
      Ukraine
      Venice
      Algeria
      Turkey
      Hungary
      Switzerland
      (Random)
    >];
    my $tpl = $p->{part} && $p->{part} eq 'statcols' ? 'started_room_info/statcols.cml' : 'started_room_info.cml';
    $h->show($tpl, {
      room => $room,
      room_time => $self->_time_interval($room->{started} || $room->{ctime}),
      backto => $backto,
      page => ($p->{page} || 1),
      res => ($p->{res} && $p->{res} =~ /^\d+$/ ? $p->{res} : 0),
      nations => $nations,
    });
  } else {
    $h->show('room_info_dgl.cml', { room => $room, room_time => $self->_time_interval($room->{started} || $room->{ctime}), backto => $backto });
  }
}

sub discord_dlg {
  my($self, $h, $p) = @_;
  $h->show('discord_dlg.cml', {});
}

sub register {
  my($self, $h, $p) = @_;
  $h->show('register.cml', { type => 'register_view' });
}

sub _time_interval {
    my($self, $ctime) = @_;
    my $time = time - $ctime;
    my @tm;

    my $d = int($time / 86400);
    $time %= 86400;
    push @tm, "${d}d" if $d;

    my $h = int($time / 3600);
    $time %= 3600;
    push @tm, "${h}h" if $h;
    return join " ", @tm if $d;

    my $m = int($time / 60);
    $time %= 60;
    push @tm, "${m}m" if $m;
    return join " ", @tm if $h || $m >= 10;

    my $s = $time;
    push @tm, "${s}s" if $s;
    return @tm ? join(" ", @tm) : "0s";
}

sub join_game {
  my($self, $h, $p) = @_;
  if($p->{VE_RID} !~ /^\d+$/) {
    $h->push_command( LW_show => "<NGDLG>\n<NGDLG>");
    return;
  }
  my $room = $h->server->data->{rooms_by_id}{ $p->{VE_RID} };
  $self->_join_to_room($h, $room, $p->{ASTATE}, $p->{VE_PASSWD} // '');
}

sub _join_to_room {
  my($self, $h, $room, $astate, $password) = @_;
  if(!$h->connection->data->{id} || !$h->connection->data->{nick}) {
    $self->_error($h, "Your was disconnected from the server. Enter again.");
    return;
  }
  if(!$astate) {
    $self->_error($h, "You can not create or join room!\nYou are already participate in some room\nPlease disconnect from that room first to create a new one");
    return;
  }
  if(!$room) {
    $self->_error($h, "You can not join this room!\nThe room is closed");
    return;
  }
  if($room->{started}) {
    $self->_error($h, "You can not join this room!\nThe game has already started");
    return;
  }
  if($room->{players_count} >= $room->{max_players}) {
    $self->_error($h, "You can not join this room!\nThe room is full");
    return;
  }
  if($room->{password} ne '' && $password ne $room->{password}) {
    $h->show('confirm_password_dgl.cml', { id => $room->{id} });
    return;
  }
  my $player_id = $h->connection->data->{id};
  $h->server->leave_room( $player_id );
  $h->server->data->{rooms_by_player}{ $player_id } = $room;
  delete $h->server->data->{rooms_by_ctlsum}->{ $room->{ctlsum} };
  $room->{players}{ $player_id } = { %{$h->server->data->{players}->{ $player_id }} };
  $room->{players_time}{ $player_id } = time;
  $room->{players_count}++;
  $room->{row}[-4] = $room->{players_count} . "/" . $room->{max_players};
  $room->{ctlsum} = $h->server->_room_control_sum($room->{row});
  $h->server->data->{rooms_by_ctlsum}->{ $room->{ctlsum} } = $room;
  my $connection = $h->connection;
  $h->show('join_room.cml' => { id => $room->{id}, max_pl => $room->{max_players}, name => $room->{title}, ip => $room->{host_addr} });
  $h->log->info($h->connection->log_message . " " . $h->req->ver . " #join room $room->{id} $room->{title}" );
}

sub user_details {
  my($self, $h, $p) = @_;
  my($id) = ($p->{ID} =~ /(\d+)/);
  my ($paramNick) = ($p->{VE_NICKNAME});
  $h->log->warn("paramNick: " . encode_json($p));
  my $nick = ($paramNick) ? $paramNick : $h->server->data->{players}{$id}{nick};
  my $backto = 'open&startup';
  if ($p->{BACKTO} && $p->{BACKTO} eq 'users_list') {
    $backto = 'open&users_list.dcml';
  }

  if (!$nick) {
    $h->log->warn("There is no info about player $id");
    $h->show('user_details.cml', {
        error => 'Data could not be retrieved',
    }); 
    return;
  }

  my $req_body = { 
    includes => ["nickName","totalPlayTime"], 
    playerToken => $h->connection->data->{account}{token}, 
    filter => {
      nickNames=> [$nick]
      }
    };
  my $response = $self->_send_json_request($h, "http://localhost:8080/players/player-details", "GET", $req_body);
  $h->log->warn("User nickName sent $nick");
  # $h->log->warn("User nickName for received player " . $response->{playerDetails}[0]->{nickName});

  if ($response && $response->{playerDetails} && $response->{playerDetails}[0]) {
    my $player = $response->{playerDetails}[0];

    $h->show('user_details.cml', {
        player => {
          nickName => $player->{nickName},
          totalPlayTime => $self->_convertSecondsToTimeString($player->{totalPlayTime}),
        },
        backto => $backto,
    }); 
  } else {
    $h->log->warn("There is no info about player $id");
    $h->show('user_details.cml', {
        error => 'Data could not be retrieved',
    }); 
  }
  
  $h->log->warn("User details page for player $id");
}

sub join_pl_cmd {
  my($self, $h, $p) = @_;
  $h->push_empty, return if $h->connection->data->{id} && $h->server->data->{rooms_by_player}{ $h->connection->data->{id} };
  my $room = $h->server->data->{rooms_by_player}{ $p->{VE_PLAYER} };
  if(!$room) {
    return;
  } elsif($room->{started}) {
     $self->_error($h, "Game alredy started"); 
    return;
  } else {
    $self->room_info_dgl($h, { VE_RID => $room->{id} });
    return;
  }
}

sub get_games_list {
    my ($self, $h) = @_;

    state $last_fetch_time = 0;
    state $cached_games_list = [];
    my $now = time();
    # Cache for 60 seconds
    if ($now - $last_fetch_time < 60 && @$cached_games_list) {
        return $cached_games_list;
    }

    my $url = "http://localhost:8080/players/game-details";
    my $req_body = { "includes" => ["teamsDetails","duration", "startTime", "gameName"], "playerToken" => $h->connection->data->{account}{token}};

    # user_details uses GET for a similar endpoint, so we use GET here as well.
    my $req = HTTP::Request->new('GET', $url);
    $req->header('Content-Type' => 'application/json');
    $req->content(encode_json($req_body));

    my $response = $ua->request($req);

    unless($response->is_success) {
      $h->log->error("bad response from $url: " . $response->status_line);
      return $cached_games_list || [];
    }

    my $result = eval { JSON::from_json($response->decoded_content) };
    unless($result) {
      $h->log->error("bad json from $url");
      return $cached_games_list || [];
    }

    my $games_list = [];
    if (ref $result eq 'HASH' && $result->{gameDetails} && ref $result->{gameDetails} eq 'ARRAY') {
        my $row_num = 1;
        for my $game (@{$result->{gameDetails}}) {
            if (ref $game eq 'HASH') {
                
                my $name = $game->{gameName};
                
                my @teams;
                if ($game->{teamsDetails} && ref $game->{teamsDetails} eq 'ARRAY') {
                    for my $team (@{$game->{teamsDetails}}) {
                        if ($team->{players} && ref $team->{players} eq 'ARRAY') {
                            push @teams, join(", ", @{$team->{players}}) . ' (' . $team->{result} . ')';
                        }
                    }
                }
                my $details = join(" vs ", @teams);

                my $durationSeconds = $game->{duration};
                my $durationStr = $self->_convertSecondsToTimeString($durationSeconds);
                my $id = unpack('L', md5($game->{startTime}, $name));

                push @$games_list, [$row_num, $id, $name, $durationStr, $details];
                $row_num++;
            }
        }
    }
    
    $last_fetch_time = $now;
    $cached_games_list = $games_list;
    return $games_list;
}

sub get_players_list {
    my ($self, $h) = @_;

    state $last_fetch_time = 0;
    state $cached_players_list = [];
    my $now = time();
    # Cache for 60 seconds to avoid hammering the endpoint from GETTBL polls.
    if ($now - $last_fetch_time < 60 && @$cached_players_list) {
        return $cached_players_list;
    }

    my $url = "http://localhost:8080/players/player-details";
    my $req_body = { "includes" => ["nickName","totalPlayTime"], "playerToken" => $h->connection->data->{account}{token}};

    my $req = HTTP::Request->new('GET', $url);
    $req->header('Content-Type' => 'application/json');
    $req->content(encode_json($req_body));

    my $response = $ua->request($req);

    unless($response->is_success) {
      $h->log->error("bad response from $url: " . $response->status_line);
      # Don't show error to user, just return cached or empty list
      return $cached_players_list || [];
    }

    my $result = eval { JSON::from_json($response->decoded_content) };
    unless($result) {
      $h->log->error("bad json from $url");
      return $cached_players_list || [];
    }

    my $players_list = [];
    my %seen_nicks;
    if (ref $result eq 'HASH' && $result->{playerDetails} && ref $result->{playerDetails} eq 'ARRAY') {
        my $row_num = 1;
        for my $player (@{$result->{playerDetails}}) {
            if (ref $player eq 'HASH' && exists $player->{nickName}) {
                my $nick = $player->{nickName};
                my $playTimeSeconds = $player->{totalPlayTime};
                my $playTimeStr = $self->_convertSecondsToTimeString($playTimeSeconds);
                next if $seen_nicks{$nick};
                $seen_nicks{$nick} = 1;
                my $id = unpack('L', md5($nick, $playTimeStr));
                push @$players_list, [$row_num, $id, $nick, $playTimeStr];
                $row_num++;
            }
        }
    }
    
    $last_fetch_time = $now;
    $cached_players_list = $players_list;
    return $players_list;
}

sub _convertSecondsToTimeString {
  my($self, $seconds) = @_;
  return $seconds < 3600 ? int($seconds / 60) . 'm' : int($seconds / 3600) . 'h';
}

sub users_list {
  my($self, $h, $p) = @_;
  my $players_list = $self->get_players_list($h);
  $h->server->data->{dbtbl}{players_list} = $players_list;
  $h->show('users_list.cml');
}

sub games_list {
  my($self, $h, $p) = @_;
  my $games_list = $self->get_games_list($h);
  $h->server->data->{dbtbl}{games_list} = $games_list;
  $h->show('games_list.cml');
}

sub _default {
  my($self, $h, $p) = @_;
  $self->_error($h, "Page Not Found");
}

sub _alert {
  my($self, $h, $header, $text) = @_;
  $h->show('alert_dgl.cml', { text => $text, header => $header });
}

sub _error {
  my($self, $h, $text) = @_;
  $h->show('alert_dgl.cml', { text => $text, header => 'Error' })
}

__PACKAGE__->meta->make_immutable();
