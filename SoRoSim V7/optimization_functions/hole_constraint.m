function [c, dc] = hole_constraint(Linkage, x,constraint_surface)
    c = [];
    q = x(1:Linkage.ndof);
    xbar1 = x(Linkage.ndof+1);

    [g_xbar1, xi_xbar1, J_xbar1] = Screw_interpolate(Linkage,xbar1, q, 1);
    xh1 = g_xbar1(1:3,4);

    eq1 = norm(constraint_surface.hole_1 - xh1)^2;
    c = [c; eq1 - (constraint_surface.radius + 0.01)^2];

    dc = zeros(length(x), length(c));
    dc(61,1) = -2*(constraint_surface.hole_1 - xh1)'*g_xbar1(1:3,1:3)*xi_xbar1(4:6);
    dc(1:60,1) = -2*(constraint_surface.hole_1 - xh1)'*g_xbar1(1:3,1:3)*J_xbar1(4:6,:);
    %% This does not consider dr_dq
end