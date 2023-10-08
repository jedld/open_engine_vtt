const Utils = {
  // function definitions go here
  manhattanDistance: function(sourceX, sourceY, destX, destY) {
    return Math.abs(sourceX - destX) + Math.abs(sourceY - destY);
  },
  euclideanDistance: function(sourceX, sourceY, destX, destY) {
    return Math.sqrt(Math.pow(sourceX - destX, 2) + Math.pow(sourceY - destY, 2));
  }
};
