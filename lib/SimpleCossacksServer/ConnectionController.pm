package SimpleCossacksServer::ConnectionController;
use Mouse;
extends 'GSC::Server::ConnectionController';

sub _connect {
  my($self, $h) = @_;
  $h->log->info($h->connection->log_message . ' #connect');
}

sub _close {
  my($self, $h) = @_;
  SimpleCossacksServer::CommandController::Open->logout_player($h);
  $h->log->info($h->connection->log_message . ' #disconnect');
}
  
__PACKAGE__->meta->make_immutable();
